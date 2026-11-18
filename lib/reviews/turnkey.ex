defmodule Reviews.Turnkey do
  @moduledoc """
  Poppy Personal Agents whose identity key lives in Turnkey.

  Turnkey can hold a Personal Agent's identity key, host its client ID
  metadata document and key set, and sign two kinds of JWT with that key
  after its policies allow it: client assertions
  (`turnkey.io/client-assertion/v1`) and delegations for the agent's session
  keys (`turnkey.io/poppy-delegation/v1`). Both are ordinary Poppy JWTs, so
  `Reviews.Poppy` already verifies them. This module adds what only a
  Turnkey-hosted agent has: it recognizes the hosted `client_id` and checks
  that the delegation has the exact shape of the Turnkey profile, so Reviews
  can say the delegation was signed by the Turnkey-held identity key.

  Everything here follows Turnkey's public draft guide, "Personal Agent
  Protocol" (tkhq/docs pull request 946, marked Beta). It is provisional
  until Turnkey ships the profiles:

    * the hosts that serve agents, `config :reviews, Reviews.Turnkey,
      agent_hosts: [...]` (default `["id.turnkey.com"]`, from the guide);
    * the URL layout `https://<host>/t/<organization ID>/agents/<agent>/agent.json`,
      with its `jwks_uri` next to it at `jwks.json`;
    * the organization ID format, which the guide doesn't specify. Any path
      segment of letters, digits, and hyphens is accepted;
    * the delegation header and claims, which the guide lists with
      "nothing else".

  "Signed by Turnkey" means the delegation verifies with the key Turnkey
  publishes for the agent and has the profile's shape. Reviews can't see
  whether the agent's organization also has the guide's DENY policy that
  keeps the key from raw-signing, so a raw signature over the same claims
  would look the same.
  """
  alias Gatekeep.{Client, Clients, JOSE}
  alias Reviews.{OAuth, Poppy}

  @delegation_profile "turnkey.io/poppy-delegation/v1"
  @max_delegation_lifetime 24 * 60 * 60
  @agent_slug ~r/\A[a-z0-9-]{1,64}\z/
  # Not specified by the guide; organization IDs appear as UUIDs.
  @organization_id ~r/\A[A-Za-z0-9-]{1,128}\z/
  @jti ~r/\A[A-Za-z0-9_-]{22,256}\z/

  @delegation_header ["alg", "kid", "typ"]
  @delegation_claims ["cnf", "exp", "iat", "iss", "jti"]
  @delegated_key_members ["crv", "kty", "x", "y"]

  def delegation_profile, do: @delegation_profile

  @doc "Reads `config :reviews, Reviews.Turnkey, key: value`."
  def config(key, default \\ nil) do
    :reviews |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  @doc """
  The Turnkey organization ID and agent slug of a Turnkey-hosted `client_id`,
  or `:error` for any other URL.
  """
  @spec hosted_agent(String.t()) ::
          {:ok, %{organization_id: String.t(), agent: String.t()}} | :error
  def hosted_agent(client_id) when is_binary(client_id) do
    hosts = config(:agent_hosts, ["id.turnkey.com"])

    with %URI{scheme: "https", host: host, port: 443, query: nil, fragment: nil, userinfo: nil} <-
           URI.parse(client_id),
         true <- host in hosts,
         # Exactly "https://<host>/t/<org>/agents/<slug>/agent.json": no
         # explicit port, no empty or extra segments.
         true <- String.starts_with?(client_id, "https://#{host}/"),
         ["", "t", org, "agents", slug, "agent.json"] <-
           String.split(URI.parse(client_id).path, "/"),
         true <- org =~ @organization_id and slug =~ @agent_slug do
      {:ok, %{organization_id: org, agent: slug}}
    else
      _ -> :error
    end
  end

  def hosted_agent(_), do: :error

  @doc """
  Verifies `jwt` as a Turnkey `poppy-delegation/v1` delegation for `client`,
  a Turnkey-hosted client from `Gatekeep.Clients.fetch/2`, vouching for
  the session key whose RFC 7638 thumbprint is `session_key`.

  Checks the client's URLs, the exact header and claims of the profile, the
  signature with the key its `kid` names in the agent's key set, that `kid`
  is that key's thumbprint, `iss`, the delegated key, the lifetime of at most
  24 hours, the times, and the `jti` format. `opts[:now]` is the current Unix
  time. Every failure is `{:error, reason}` with a specific atom.
  """
  @spec verify_delegation(String.t(), Client.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def verify_delegation(jwt, client, session_key, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)
    skew = Poppy.config(:clock_skew_seconds, 30)

    with {:ok, agent} <- hosted_client(client),
         {:ok, jws} <- JOSE.decode(jwt),
         :ok <- check_header(jws.header),
         {:ok, key} <- identity_key(client, jws.header["kid"]),
         :ok <- expect(JOSE.verify(jws, key, ["ES256"]), :bad_signature),
         {:ok, kid} <- JOSE.thumbprint(key),
         :ok <- expect(jws.header["kid"] == kid, :kid_not_thumbprint),
         :ok <- expect(sorted_keys(jws.claims) == @delegation_claims, :unexpected_claims),
         %{"iss" => iss, "iat" => iat, "exp" => exp, "jti" => jti, "cnf" => cnf} = jws.claims,
         :ok <- expect(iss == client.client_id, :iss_mismatch),
         {:ok, delegated} <- delegated_key(cnf),
         :ok <- expect(delegated != kid, :delegated_identity_key),
         :ok <- expect(delegated == session_key, :different_session_key),
         :ok <- expect(is_integer(iat) and is_integer(exp), :bad_times),
         :ok <- expect((exp - iat) in 1..@max_delegation_lifetime, :bad_lifetime),
         :ok <- expect(exp > now - skew, :expired),
         :ok <- expect(iat <= now + skew, :issued_in_future),
         :ok <- expect(is_binary(jti) and jti =~ @jti, :bad_jti) do
      {:ok,
       Map.merge(agent, %{
         profile: @delegation_profile,
         identity_key: kid,
         jti: jti,
         issued_at: iat,
         expires_at: exp
       })}
    end
  end

  # The client_id is a Turnkey agent URL and its key set is the one next to it.
  defp hosted_client(%{client_id: client_id, jwks_uri: jwks_uri}) do
    with {:ok, agent} <- hosted_agent(client_id),
         true <- jwks_uri == String.replace_suffix(client_id, "/agent.json", "/jwks.json") do
      {:ok, agent}
    else
      _ -> {:error, :not_turnkey_hosted}
    end
  end

  defp check_header(header) do
    cond do
      sorted_keys(header) != @delegation_header -> {:error, :unexpected_header}
      header["typ"] != "poppy-delegation+jwt" -> {:error, :bad_typ}
      header["alg"] != "ES256" -> {:error, :bad_alg}
      not is_binary(header["kid"]) -> {:error, :unknown_key}
      true -> :ok
    end
  end

  # The profile signs with a P-256 key; other key types in the set don't count.
  defp identity_key(client, kid) do
    case Clients.key(OAuth.config(), client, kid) do
      {:ok, %{"kty" => "EC", "crv" => "P-256"} = key} -> {:ok, key}
      _ -> {:error, :unknown_key}
    end
  end

  # cnf.jwk holds only the public members of a P-256 key.
  defp delegated_key(%{"jwk" => jwk} = cnf) when map_size(cnf) == 1 and is_map(jwk) do
    with true <- sorted_keys(jwk) == @delegated_key_members,
         %{"kty" => "EC", "crv" => "P-256"} <- jwk,
         true <- JOSE.public_key?(jwk),
         {:ok, thumbprint} <- JOSE.thumbprint(jwk) do
      {:ok, thumbprint}
    else
      _ -> {:error, :bad_delegated_key}
    end
  end

  defp delegated_key(_cnf), do: {:error, :bad_delegated_key}

  defp sorted_keys(map) when is_map(map), do: map |> Map.keys() |> Enum.sort()

  defp expect(true, _reason), do: :ok
  defp expect(_, reason), do: {:error, reason}
end
