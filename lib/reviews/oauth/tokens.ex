defmodule Reviews.OAuth.Tokens do
  @moduledoc """
  Verifies the JWTs clients sign for the issuer: `private_key_jwt` client
  assertions (RFC 7523), and the replay cache they share with other JWTs.

  Every failure returns `{:error, reason}` with a specific atom so tests and
  logs can tell cases apart. The HTTP layer maps them to OAuth errors, which
  don't reveal the reason.
  """
  import Ecto.Query, only: [from: 2]

  alias Reviews.OAuth
  alias Reviews.OAuth.{Clients, JOSE}
  alias Reviews.Repo

  @max_assertion_lifetime 5 * 60

  @doc """
  Verifies a `private_key_jwt` client assertion at the token or revocation
  endpoint. Returns the verified client.

  `aud` must be the issuer (RFC 7523bis §4). Clients listed in
  `:token_endpoint_audience_clients` may also address the token endpoint.
  """
  @spec verify_client_assertion(map(), keyword()) :: {:ok, Clients.client()} | {:error, atom()}
  def verify_client_assertion(params, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &now/0)
    issuer = Keyword.get_lazy(opts, :issuer, &OAuth.issuer/0)
    skew = OAuth.config(:clock_skew_seconds, 30)

    with "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" <-
           params["client_assertion_type"],
         assertion when is_binary(assertion) <- params["client_assertion"],
         {:ok, jws} <- JOSE.decode(assertion),
         %{"iss" => iss, "sub" => iss, "aud" => aud, "exp" => exp, "iat" => iat, "jti" => jti}
         when is_binary(iss) and is_integer(exp) and is_integer(iat) and is_binary(jti) <-
           jws.claims,
         :ok <- expect(params["client_id"] in [nil, iss], :client_id_mismatch),
         :ok <- expect(audience?(aud, iss, issuer), :wrong_audience),
         {:ok, client} <- Clients.fetch(iss),
         :ok <- expect("private_key_jwt" in client.auth_methods, :auth_method_not_allowed),
         :ok <- verify_with_client_keys(jws, client),
         :ok <- expect(exp > now - skew, :expired),
         :ok <- expect(iat <= now + skew, :issued_in_future),
         :ok <- expect(exp - iat <= @max_assertion_lifetime, :assertion_too_long),
         :ok <- expect(jti != "" and byte_size(jti) <= 255, :bad_jti),
         :ok <- remember_jti("assertion", iss, jti, exp + skew) do
      {:ok, client}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_assertion}
    end
  end

  defp audience?(aud, iss, issuer) when is_binary(aud) do
    aud == issuer or
      (aud == issuer <> "/oauth/token" and
         iss in OAuth.config(:token_endpoint_audience_clients, []))
  end

  defp audience?(_aud, _iss, _issuer), do: false

  defp verify_with_client_keys(jws, client) do
    keys =
      case jws.header["kid"] do
        kid when is_binary(kid) ->
          case Clients.key(client, kid) do
            {:ok, key} -> [key]
            _ -> []
          end

        _ ->
          client.keys
      end

    if Enum.any?(keys, &JOSE.verify(jws, &1, ["ES256", "PS384", "RS256"])),
      do: :ok,
      else: {:error, :bad_signature}
  end

  @doc """
  Records `jti` of kind `kind` for `client_id` until `expires_at`. Returns
  `{:error, :replayed}` when another request already used it, on any server.
  """
  def remember_jti(kind, client_id, jti, expires_at) do
    expires = DateTime.from_unix!(expires_at)

    {count, _} =
      Repo.insert_all(
        "oauth_seen_jtis",
        [%{kind: kind, client_id: client_id, jti: jti, expires_at: expires}],
        on_conflict: :nothing,
        conflict_target: [:kind, :client_id, :jti]
      )

    if count == 1 do
      prune_expired_jtis()
      :ok
    else
      {:error, :replayed}
    end
  end

  # Keep the replay table small without a scheduled job: about one write in
  # fifty clears entries whose window has passed.
  defp prune_expired_jtis do
    if :rand.uniform(50) == 1 do
      now = DateTime.utc_now()
      Repo.delete_all(from j in "oauth_seen_jtis", where: j.expires_at < ^now)
    end

    :ok
  end

  defp expect(true, _reason), do: :ok
  defp expect(_, reason), do: {:error, reason}

  defp now, do: System.system_time(:second)
end
