defmodule Reviews.Poppy.Tokens do
  @moduledoc """
  Verifies the Session JWTs a Personal Agent signs, with their delegations
  (spec 5.2, 5.3). Client assertions are the issuer's
  (`Reviews.OAuth.Tokens`), and so is the replay cache both use.

  Every failure returns `{:error, reason}` with a specific atom so tests and
  logs can tell cases apart. The HTTP layer maps them to the spec's errors,
  which don't reveal the reason.
  """
  alias Reviews.OAuth
  alias Reviews.OAuth.{Clients, JOSE}
  alias Reviews.Poppy

  @max_delegation_lifetime 24 * 60 * 60
  @id_format ~r/\A[A-Za-z0-9_-]{1,256}\z/

  @type request :: %{method: String.t(), url: String.t(), access_token: String.t() | nil}

  @type session_claims :: %{
          client: Clients.client(),
          sid: String.t(),
          sub: String.t(),
          agent_id: String.t() | nil,
          iat: integer(),
          jti: String.t(),
          delegated_key: String.t(),
          delegation_exp: integer()
        }

  @doc """
  Verifies a Session JWT for `request`. `opts[:audience]` is the Company
  identifier (default `Reviews.OAuth.issuer/0`) and `opts[:now]` the current Unix time.
  On success the JWT's `jti` is recorded, so the same JWT is refused next time.
  """
  @spec verify_session(String.t(), request(), keyword()) ::
          {:ok, session_claims()} | {:error, atom()}
  def verify_session(jwt, request, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &now/0)
    audience = Keyword.get_lazy(opts, :audience, &OAuth.issuer/0)
    window = Poppy.config(:session_window_seconds, 60)
    skew = Poppy.config(:clock_skew_seconds, 30)

    with {:ok, jws} <- JOSE.decode(jwt),
         :ok <- check_session_header(jws.header),
         %{"iss" => iss} when is_binary(iss) <- jws.claims,
         {:ok, client} <- Clients.fetch(iss),
         {:ok, delegated_key, delegation_exp} <-
           verify_delegation(jws.header["poppy_dlg"], client, now, skew),
         :ok <- verify_signature(jws, delegated_key, ["ES256"], :bad_signature),
         {:ok, thumbprint} <- JOSE.thumbprint(delegated_key),
         :ok <- expect(jws.header["kid"] == thumbprint, :kid_not_thumbprint),
         {:ok, claims} <- check_session_claims(jws.claims, request, audience, now, window, skew),
         :ok <- OAuth.Tokens.remember_jti("session", iss, claims.jti, claims.iat + window + skew) do
      {:ok,
       Map.merge(claims, %{
         client: client,
         delegated_key: thumbprint,
         delegation_exp: delegation_exp
       })}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_claims}
    end
  end

  defp check_session_header(
         %{"typ" => "poppy-session+jwt", "alg" => "ES256", "kid" => kid} = header
       )
       when is_binary(kid) do
    if is_binary(header["poppy_dlg"]), do: :ok, else: {:error, :missing_delegation}
  end

  defp check_session_header(%{"typ" => "poppy-session+jwt", "alg" => "ES256"}),
    do: {:error, :missing_kid}

  defp check_session_header(%{"typ" => "poppy-session+jwt"}), do: {:error, :bad_alg}
  defp check_session_header(_), do: {:error, :bad_typ}

  # Delegated keys (spec 5.2): verify the delegation with the key in jwks_uri
  # that its kid names, then its typ, iss, expiry, and lifetime.
  defp verify_delegation(dlg, client, now, skew) do
    with {:ok, jws} <- JOSE.decode(dlg),
         :ok <- expect(jws.header["typ"] == "poppy-delegation+jwt", :bad_delegation_typ),
         {:ok, root_key} <- Clients.key(client, jws.header["kid"]),
         :ok <- verify_signature(jws, root_key, ["ES256", "PS384"], :bad_delegation_signature),
         %{"iss" => iss, "iat" => iat, "exp" => exp, "cnf" => %{"jwk" => jwk}}
         when is_integer(iat) and is_integer(exp) and is_map(jwk) <- jws.claims,
         :ok <- expect(iss == client.client_id, :delegation_iss_mismatch),
         :ok <- expect(exp > now - skew, :delegation_expired),
         :ok <- expect(exp - iat <= @max_delegation_lifetime, :delegation_too_long),
         :ok <- expect(iat <= now + skew, :delegation_not_yet_valid),
         :ok <- expect(JOSE.public_key?(jwk) and jwk["kty"] == "EC", :bad_delegated_key) do
      {:ok, jwk, exp}
    else
      {:error, :malformed} -> {:error, :bad_delegation}
      {:error, :unknown_key} -> {:error, :unknown_delegation_key}
      {:error, _} = error -> error
      _ -> {:error, :bad_delegation}
    end
  end

  defp check_session_claims(claims, request, audience, now, window, skew) do
    with %{"aud" => aud, "sid" => sid, "sub" => sub, "htm" => htm, "htu" => htu} <- claims,
         %{"iat" => iat, "jti" => jti} when is_integer(iat) and is_binary(jti) <- claims,
         :ok <- expect(aud == audience, :wrong_audience),
         :ok <- expect(is_binary(sid) and sid =~ @id_format, :bad_sid),
         :ok <- expect(is_binary(sub) and sub != "" and byte_size(sub) <= 255, :bad_sub),
         :ok <- expect(valid_agent_id?(claims["agent_id"]), :bad_agent_id),
         :ok <- expect(htm == request.method, :wrong_method),
         :ok <- expect(htu_matches?(htu, request.url), :wrong_url),
         :ok <- expect(iat >= now - window - skew, :expired),
         :ok <- expect(iat <= now + skew, :issued_in_future),
         :ok <- expect(jti != "" and byte_size(jti) <= 255, :bad_jti),
         :ok <- check_ath(claims["ath"], request[:access_token]) do
      {:ok, %{sid: sid, sub: sub, agent_id: claims["agent_id"], iat: iat, jti: jti}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_claims}
    end
  end

  defp valid_agent_id?(nil), do: true
  defp valid_agent_id?(id), do: is_binary(id) and id != "" and byte_size(id) <= 255

  # Spec 5.3 step 3: `ath` matches the access token, or is absent without one.
  defp check_ath(nil, nil), do: :ok
  defp check_ath(_ath, nil), do: {:error, :ath_without_token}
  defp check_ath(nil, _token), do: {:error, :missing_ath}
  defp check_ath(ath, token), do: expect(ath == JOSE.digest(token), :ath_mismatch)

  # RFC 9449 §4.3: compare without query and fragment, after normalizing the
  # scheme and host case and the default port.
  defp htu_matches?(htu, url) when is_binary(htu), do: normalize_url(htu) == normalize_url(url)
  defp htu_matches?(_htu, _url), do: false

  defp normalize_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        scheme = String.downcase(scheme)
        port = if uri.port in [nil, URI.default_port(scheme)], do: "", else: ":#{uri.port}"
        "#{scheme}://#{String.downcase(host)}#{port}#{uri.path || "/"}"

      _ ->
        :invalid
    end
  end

  defp verify_signature(jws, key, algs, error) do
    if JOSE.verify(jws, key, algs), do: :ok, else: {:error, error}
  end

  defp expect(true, _reason), do: :ok
  defp expect(_, reason), do: {:error, reason}

  defp now, do: System.system_time(:second)
end
