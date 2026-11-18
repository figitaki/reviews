defmodule Reviews.Poppy.Adapter do
  @moduledoc """
  `Reviews.ExternalIdentity` for Poppy 1.0 requests: a `Poppy-Session` header,
  `Poppy-Version`, and, when signed in, an access token from Direct Sign-In.

  Order of checks (spec 3.4, 5.3): version, Session JWT and delegation, the
  access token with its grant and DPoP binding (spec 4.5, RFC 9449 §7;
  `Reviews.OAuth.authenticate_access_token/2`), that the token was issued to
  the JWT's `iss`, then the Session record.

  `headers` holds the first value of each header, except `"dpop"`, which is
  the list of every `DPoP` header value.
  """
  @behaviour Reviews.ExternalIdentity

  alias Reviews.{OAuth, Poppy}
  alias Reviews.Poppy.Tokens

  @impl true
  def authenticate(%{method: method, url: url, headers: headers}, opts \\ []) do
    {_scheme, token} = credentials(headers["authorization"])

    with :ok <- check_version(headers["poppy-version"]),
         {:ok, jwt} <- session_header(headers["poppy-session"]),
         {:ok, claims} <-
           Tokens.verify_session(jwt, %{method: method, url: url, access_token: token}, opts),
         {:ok, access} <- access(token, method, url, headers),
         :ok <- same_client(access, claims),
         {:ok, session} <- Poppy.touch_session(claims, access && access.grant.identity.id) do
      {:ok, result(claims, access, session)}
    end
  end

  @doc """
  The scheme and token of an `Authorization` header: `{:bearer, token}`,
  `{:dpop, token}`, or `{nil, nil}`. Schemes are compared ignoring case
  (RFC 9110 §11.1).
  """
  def credentials(authorization) when is_binary(authorization) do
    case String.split(authorization, " ", parts: 2) do
      [scheme, token] when token != "" ->
        case String.downcase(scheme) do
          "bearer" -> {:bearer, token}
          "dpop" -> {:dpop, token}
          _ -> {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  def credentials(_), do: {nil, nil}

  # Compatible versions share the major version (spec 3.4).
  defp check_version("1." <> minor) do
    if minor =~ ~r/\A\d+\z/, do: :ok, else: {:error, :version_unsupported}
  end

  defp check_version(_), do: {:error, :version_unsupported}

  defp session_header(jwt) when is_binary(jwt) and jwt != "", do: {:ok, jwt}
  defp session_header(_), do: {:error, :missing_session}

  # A Bearer token comes with the Bearer scheme. A DPoP-bound token comes with
  # the DPoP scheme and a proof from its key, over the configured public URL
  # of this request, never the Host header; as a bearer token it is refused,
  # so it can't be downgraded (RFC 9449 §7.2). A bad proof is
  # invalid_dpop_proof, and any other problem invalid_token.
  defp access(nil, _method, _url, _headers), do: {:ok, nil}

  defp access(_token, method, url, headers) do
    OAuth.authenticate_access_token(Poppy.resource(), %{
      authorization: headers["authorization"],
      dpop: headers["dpop"] || [],
      method: method,
      path: URI.parse(url).path
    })
  end

  # Spec 5.3 step 3: the token was issued to the same client_id as `iss`.
  defp same_client(nil, _claims), do: :ok

  defp same_client(%{token: token}, %{client: client}) do
    if token.client_id == client.client_id, do: :ok, else: {:error, :token_client_mismatch}
  end

  defp result(claims, nil, session) do
    %{
      identity: nil,
      owner: nil,
      grant: nil,
      scopes: [],
      attribution: attribution(claims, nil, session)
    }
  end

  defp result(claims, %{grant: grant, token: token}, session) do
    attribution =
      claims
      |> attribution(grant, session)
      |> Map.put("access_token_dpop_key", token.dpop_jkt)

    %{
      identity: grant.identity,
      owner: grant.approved_by_user,
      grant: grant,
      scopes: token.scopes,
      attribution: attribution
    }
  end

  # What was verified, kept with the records the request creates. The
  # Personal Agent's name and Agent ID are its own claims; the owner and agent
  # identity come from the owner's approval in Reviews. `link_id` is the
  # grant's ID; the name predates gatekeep and stays for stored comments.
  # Poppy 1.0 has no
  # workload attestation or owner-to-agent delegation chain, so neither is
  # recorded as verified.
  defp attribution(claims, grant, session) do
    %{
      "provider" => Poppy.provider(),
      "protocol_version" => Poppy.protocol_version(),
      "verified_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "client_id" => claims.client.client_id,
      "client_name_claimed" => claims.client.client_name,
      "session_id" => session.id,
      "user_id" => claims.sub,
      "agent_id_claimed" => claims.agent_id,
      "delegated_key" => claims.delegated_key,
      "delegation_expires_at" =>
        DateTime.from_unix!(claims.delegation_exp) |> DateTime.to_iso8601()
    }
    |> Map.merge(grant_attribution(grant))
  end

  defp grant_attribution(nil), do: %{}

  defp grant_attribution(grant) do
    %{
      "link_id" => grant.id,
      "approved_at" => DateTime.to_iso8601(grant.inserted_at),
      "owner_user_id" => grant.approved_by_user.id,
      "owner_username" => grant.approved_by_user.username,
      "identity_id" => grant.identity.id,
      "identity_handle" => grant.identity.handle
    }
  end
end
