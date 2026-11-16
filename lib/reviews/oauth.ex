defmodule Reviews.OAuth do
  @moduledoc """
  The Reviews OAuth 2.1 issuer: authorization with PKCE, consent, the token
  endpoint, refresh, and revocation.

  An app never gets account access by itself. The owner signs in to Reviews
  with GitHub, picks one of their agent identities, and approves scopes for
  one resource. The approval is an `Reviews.Accounts.IdentityLink`, and every
  token issued under it acts as that agent identity, never as the person. No
  new account or actor namespace is created.

  Clients are identified by a client ID metadata document (an HTTPS
  `client_id`) or registered through dynamic client registration
  (`Reviews.OAuth.Registration`); see `Reviews.OAuth.Clients`.

  The APIs that accept these tokens are `Reviews.OAuth.Resource` modules,
  listed in `config :reviews, Reviews.OAuth, resources: [...]`. The `resource`
  parameter (RFC 8707) of the authorization request picks one. A request
  without it goes to the resource whose scopes it names, or to
  `:default_resource`. Each link's tokens work only at its own resource.
  """
  import Ecto.Query, warn: false

  alias Reviews.Accounts
  alias Reviews.Accounts.{Identity, IdentityLink, User}
  alias Reviews.OAuth.{AccessToken, AuthorizationCode, Clients}
  alias Reviews.Repo

  @code_ttl 120
  @access_token_ttl 60 * 60
  @refresh_token_ttl 90 * 24 * 60 * 60

  @doc "Reads `config :reviews, Reviews.OAuth, key: value`."
  def config(key, default \\ nil) do
    :reviews |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end

  @doc """
  The issuer identifier (RFC 8414), which is also the audience of client
  assertions. Defaults to the endpoint's public URL.
  """
  def issuer do
    config(:issuer) || ReviewsWeb.Endpoint.url()
  end

  @doc "Every configured resource module, enabled or not."
  def resources, do: config(:resources, [])

  @doc "The resources the issuer grants tokens for right now."
  def enabled_resources, do: Enum.filter(resources(), & &1.enabled?())

  @doc "The resource module whose links have `provider`, or nil."
  def resource_for(provider), do: Enum.find(resources(), &(&1.provider() == provider))

  @doc "Whether an enabled resource takes public clients, which also turns on registration."
  def public_clients?, do: Enum.any?(enabled_resources(), &("none" in &1.client_auth_methods()))

  @doc "The scope descriptions of the resource whose links have `provider`."
  def scope_descriptions(provider) do
    case resource_for(provider) do
      nil -> %{}
      resource -> resource.scopes()
    end
  end

  ## Authorization (OAuth 2.1 §4.1)

  @doc """
  Checks an authorization request. Errors that must not redirect (an unusable
  client or redirect URI) return `{:error, reason}`. Others return
  `{:redirect_error, code, request}` so the caller can redirect with `iss`.
  """
  def check_authorization_request(params) do
    client_id = params["client_id"]
    redirect_uri = params["redirect_uri"]

    with {:ok, client} <- Clients.fetch(client_id || ""),
         :ok <- check_redirect_uri(client, redirect_uri) do
      request = %{
        client: client,
        redirect_uri: redirect_uri,
        state: params["state"],
        scope: params["scope"],
        code_challenge: params["code_challenge"],
        dpop_jkt: params["dpop_jkt"],
        provider: nil,
        resource: nil
      }

      cond do
        params["response_type"] != "code" ->
          {:redirect_error, "unsupported_response_type", request}

        not is_binary(request.code_challenge) or params["code_challenge_method"] != "S256" or
            not (request.code_challenge =~ ~r/\A[A-Za-z0-9_-]{43}\z/) ->
          {:redirect_error, "invalid_request", request}

        # RFC 9449 §10: an optional SHA-256 JWK thumbprint the code is bound to.
        not (is_nil(request.dpop_jkt) or
                 (is_binary(request.dpop_jkt) and request.dpop_jkt =~ ~r/\A[A-Za-z0-9_-]{43}\z/)) ->
          {:redirect_error, "invalid_request", request}

        true ->
          case requested_grant(params["resource"], params["scope"], client) do
            {:ok, grant} -> {:ok, request |> Map.merge(grant) |> drop_unsupported_dpop()}
            {:error, error} -> {:redirect_error, error, request}
          end
      end
    else
      {:error, :redirect_uri} -> {:error, :invalid_redirect_uri}
      {:error, _} -> {:error, :invalid_client}
    end
  end

  # Only a resource that takes DPoP-bound tokens binds codes to a key.
  defp drop_unsupported_dpop(request) do
    if dpop?(resource_for(request.provider)), do: request, else: %{request | dpop_jkt: nil}
  end

  @doc """
  Whether the resource takes DPoP-bound tokens (RFC 9449): it lists proof
  algorithms in `dpop_signing_algs/0`, an optional callback.
  """
  def dpop?(nil), do: false

  def dpop?(resource),
    do: function_exported?(resource, :dpop_signing_algs, 0) and resource.dpop_signing_algs() != []

  # Which resource the request is for, and its scopes.
  defp requested_grant(resource_param, scope, client) do
    with {:ok, resource} <- select_resource(resource_param, scope),
         :ok <- check_client_methods(resource, client) do
      case resource.parse_scopes(scope) do
        {:ok, scopes} ->
          {:ok, %{provider: resource.provider(), resource: resource.resource(), scopes: scopes}}

        :error ->
          {:error, "invalid_scope"}
      end
    end
  end

  # A named resource must be one this issuer serves. Without one, the
  # resource whose scopes the request names, or else the default resource.
  defp select_resource(resource_param, _scope) when is_binary(resource_param) do
    case Enum.find(enabled_resources(), &resource_is?(resource_param, &1.resource())) do
      nil -> {:error, "invalid_target"}
      resource -> {:ok, resource}
    end
  end

  defp select_resource(_resource_param, scope) do
    named =
      if is_binary(scope) and String.trim(scope) != "",
        do: Enum.find(enabled_resources(), &match?({:ok, _}, &1.parse_scopes(scope)))

    default = config(:default_resource)

    cond do
      named -> {:ok, named}
      default && default.enabled?() -> {:ok, default}
      true -> {:error, "invalid_scope"}
    end
  end

  # A client must be able to authenticate the way the resource needs, such
  # as a resource that only takes clients with keys.
  defp check_client_methods(resource, client) do
    if Enum.any?(client.auth_methods, &(&1 in resource.client_auth_methods())),
      do: :ok,
      else: {:error, "unauthorized_client"}
  end

  # RFC 8707 resources compare without case in the scheme and host, a default
  # port, or a trailing slash, as Claude sends them.
  @doc false
  def resource_is?(candidate, resource) when is_binary(candidate),
    do: canonical_resource(candidate) == canonical_resource(resource)

  def resource_is?(_candidate, _resource), do: false

  defp canonical_resource(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, query: nil, fragment: nil, userinfo: nil} = uri
      when is_binary(scheme) and is_binary(host) ->
        scheme = String.downcase(scheme)
        port = if uri.port in [nil, URI.default_port(scheme)], do: "", else: ":#{uri.port}"
        "#{scheme}://#{String.downcase(host)}#{port}#{String.trim_trailing(uri.path || "", "/")}"

      _ ->
        :invalid
    end
  end

  # Exact match, except the port of a loopback redirect URI (RFC 8252 §7.3).
  defp check_redirect_uri(%{redirect_uris: uris}, redirect_uri) when is_binary(redirect_uri) do
    matches? =
      Enum.any?(uris, fn registered ->
        registered == redirect_uri or
          (Clients.loopback_redirect?(registered) and Clients.loopback_redirect?(redirect_uri) and
             without_port(registered) == without_port(redirect_uri))
      end)

    if matches?, do: :ok, else: {:error, :redirect_uri}
  end

  defp check_redirect_uri(_client, _uri), do: {:error, :redirect_uri}

  defp without_port(url) do
    uri = URI.parse(url)
    {uri.scheme, uri.host, uri.path, uri.query}
  end

  @doc """
  The owner approves `request` for one of their agent identities. Returns the
  raw one-time code. The identity must be an agent that belongs to `user`;
  the owner's human identity and any other ID are refused, so an OAuth app
  never acts as the person.
  """
  def approve(%User{} = user, identity_id, request, granted_scopes) do
    # IDs are bigints; a larger number would make the query raise.
    with {:ok, id} when is_integer(id) and id <= 9_223_372_036_854_775_807 <-
           Ecto.Type.cast(:id, identity_id),
         %Identity{kind: "agent"} = identity <- Accounts.get_owned_identity(user, id),
         true <- granted_scopes != [] and granted_scopes -- request.scopes == [] do
      code = random_token("ppc_")

      %AuthorizationCode{
        code_hash: hash(code),
        client_id: request.client.client_id,
        client_name: request.client.client_name,
        redirect_uri: request.redirect_uri,
        code_challenge: request.code_challenge,
        dpop_jkt: request.dpop_jkt,
        provider: request.provider,
        resource: request.resource,
        scopes: granted_scopes,
        identity_id: identity.id,
        user_id: user.id,
        expires_at: in_seconds(@code_ttl)
      }
      |> Repo.insert!()

      {:ok, code}
    else
      _ -> {:error, :invalid_identity}
    end
  end

  ## Token endpoint (OAuth 2.1 §3.2)

  @doc """
  Exchanges a code for tokens. The code is consumed atomically, so two
  concurrent exchanges can't both succeed. Reusing a code revokes the link it
  created (RFC 6749 §4.1.2), when the same client presents it.

  Consuming the code and creating its link happen in one transaction. The
  update holds the code's row lock until then, so a concurrent reuse waits
  and finds the link to revoke.

  `dpop_jkt` is the thumbprint of the request's verified DPoP proof key, or
  nil. For a resource that takes DPoP, the refresh token and access token are
  bound to it and `token_type` is `DPoP`; without a key they are Bearer. A
  code whose authorization request named a `dpop_jkt` needs a proof from that
  key (RFC 9449 §10). Other resources ignore the key.
  """
  def exchange_code(client_id, auth_method, params, dpop_jkt \\ nil) do
    code = params["code"]
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from c in AuthorizationCode,
        where: c.code_hash == ^hash(code || "") and is_nil(c.consumed_at),
        select: c

    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.update_all(query, set: [consumed_at: now]) do
          {1, [code_row]} ->
            redeem_code(code_row, client_id, auth_method, params, now, dpop_jkt)

          {0, _} ->
            revoke_reused_code(code, client_id, auth_method)
            {:error, :invalid_grant}
        end
      end)

    result
  end

  # A failed check still commits `consumed_at`: a code gets one attempt.
  defp redeem_code(code_row, client_id, auth_method, params, now, dpop_jkt) do
    resource = resource_for(code_row.provider)
    dpop_jkt = if dpop?(resource), do: dpop_jkt

    with :ok <- expect(code_row.client_id == client_id),
         :ok <- expect(DateTime.compare(code_row.expires_at, now) == :gt),
         :ok <- expect(code_row.redirect_uri == params["redirect_uri"]),
         :ok <- check_pkce(code_row.code_challenge, params["code_verifier"]),
         :ok <- expect(is_nil(code_row.dpop_jkt) or code_row.dpop_jkt == dpop_jkt),
         :ok <- check_auth_method(resource, auth_method),
         :ok <- check_enabled(resource),
         :ok <- check_resource(params["resource"], code_row.resource) do
      create_link(code_row, dpop_jkt)
    else
      {:error, :invalid_target} -> {:error, :invalid_target}
      _ -> {:error, :invalid_grant}
    end
  end

  defp check_auth_method(nil, _method), do: :error

  defp check_auth_method(resource, method),
    do: expect(method in resource.client_auth_methods())

  # A disabled resource issues no tokens, from codes or refresh tokens.
  defp check_enabled(resource), do: expect(resource.enabled?())

  defp check_pkce(challenge, verifier)
       when is_binary(verifier) and byte_size(verifier) in 43..128 do
    expect(Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) == challenge)
  end

  defp check_pkce(_challenge, _verifier), do: :error

  # Only the client the code was issued to, authenticated the way its
  # resource requires, can revoke the grant by reusing the code. Another
  # client gets `invalid_grant` and changes nothing.
  defp revoke_reused_code(code, client_id, auth_method) when is_binary(code) do
    case Repo.get_by(AuthorizationCode, code_hash: hash(code)) do
      %AuthorizationCode{identity_link_id: link_id, client_id: ^client_id} = row
      when is_integer(link_id) ->
        if check_auth_method(resource_for(row.provider), auth_method) == :ok,
          do: revoke_link_by_id(link_id)

      _ ->
        :ok
    end
  end

  defp revoke_reused_code(_code, _client_id, _auth_method), do: :ok

  defp create_link(%AuthorizationCode{} = code, dpop_jkt) do
    refresh_token = random_token("ppr_")

    Repo.transaction(fn ->
      link =
        %IdentityLink{}
        |> IdentityLink.changeset(%{
          identity_id: code.identity_id,
          approved_by_user_id: code.user_id,
          provider: code.provider,
          subject: code.client_id,
          subject_name: code.client_name,
          scopes: code.scopes,
          refresh_token_hash: hash(refresh_token),
          dpop_jkt: dpop_jkt
        })
        |> Repo.insert!()

      Repo.update_all(from(c in AuthorizationCode, where: c.id == ^code.id),
        set: [identity_link_id: link.id]
      )

      issue_access_token(link, code.scopes, dpop_jkt)
      |> Map.put("refresh_token", refresh_token)
    end)
  end

  @doc """
  Refresh. The scope may narrow the grant, never widen it.

  A resource with rotating refresh tokens gets a new one in the response, and
  the old one stops working. Presenting a replaced token again means it
  leaked or was copied, so it revokes the link and every token issued under
  it (OAuth 2.1 §4.3.1). Other refresh tokens are not rotated.

  A refresh token bound to a DPoP key needs a proof from that key: a missing
  proof or another key is `invalid_grant`. An unbound refresh token stays
  unbound, and the access token is bound to the proof's key if the request
  has one and the resource takes DPoP (RFC 9449 §5).
  """
  def refresh(client_id, auth_method, params, dpop_jkt \\ nil) do
    hash = hash(params["refresh_token"] || "")
    providers = Enum.map(resources(), & &1.provider())

    # The row lock makes concurrent refreshes with one token take turns: the
    # second finds the token already rotated away, which is reuse.
    {:ok, result} =
      Repo.transaction(fn ->
        link =
          Repo.one(
            from l in IdentityLink,
              where: l.refresh_token_hash == ^hash and l.provider in ^providers,
              lock: "FOR UPDATE"
          )

        case link do
          %IdentityLink{} = link ->
            resource = resource_for(link.provider)
            dpop_jkt = if dpop?(resource), do: dpop_jkt
            refresh_link(link, resource, hash, client_id, auth_method, params, dpop_jkt)

          nil ->
            revoke_reused_refresh_token(hash, client_id, auth_method)
            {:error, :invalid_grant}
        end
      end)

    result
  end

  defp refresh_link(link, resource, hash, client_id, auth_method, params, dpop_jkt) do
    with :ok <- expect(link.subject == client_id),
         :ok <- check_auth_method(resource, auth_method),
         :ok <- check_enabled(resource),
         :ok <- expect(active_link?(link)),
         :ok <- expect(is_nil(link.dpop_jkt) or link.dpop_jkt == dpop_jkt),
         {:ok, scopes} <- requested_scopes(params["scope"], link.scopes, resource),
         :ok <- check_resource(params["resource"], resource.resource()),
         {:ok, refresh_token} <- maybe_rotate(resource, link, hash) do
      body = issue_access_token(link, scopes, dpop_jkt)
      {:ok, if(refresh_token, do: Map.put(body, "refresh_token", refresh_token), else: body)}
    else
      {:error, :invalid_scope} -> {:error, :invalid_scope}
      {:error, :invalid_target} -> {:error, :invalid_target}
      _ -> {:error, :invalid_grant}
    end
  end

  defp maybe_rotate(resource, link, hash) do
    if resource.rotate_refresh_tokens?(), do: rotate_refresh_token(link, hash), else: {:ok, nil}
  end

  # Replaces the refresh token and records the old one as consumed, for the
  # grant's lifetime. Runs under the row lock `refresh/3` takes. Should the
  # swap still miss, the token is being used twice, so the grant ends.
  defp rotate_refresh_token(link, hash) do
    refresh_token = random_token("ppr_")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from l in IdentityLink,
        where: l.id == ^link.id and l.refresh_token_hash == ^hash and is_nil(l.revoked_at)

    case Repo.update_all(query, set: [refresh_token_hash: hash(refresh_token), updated_at: now]) do
      {1, _} ->
        Repo.insert_all("oauth_consumed_refresh_tokens", [
          %{identity_link_id: link.id, token_hash: hash, inserted_at: now}
        ])

        {:ok, refresh_token}

      {0, _} ->
        revoke_link_by_id(link.id)
        :error
    end
  end

  # Any refresh token a grant rotated away revokes the grant, when the
  # grant's own client presents it, authenticated the way its resource
  # requires. Another client gets `invalid_grant` and changes nothing.
  defp revoke_reused_refresh_token(hash, client_id, auth_method) do
    case Repo.one(
           from c in "oauth_consumed_refresh_tokens",
             join: l in IdentityLink,
             on: l.id == c.identity_link_id,
             where: c.token_hash == ^hash and l.subject == ^client_id,
             select: {l.id, l.provider}
         ) do
      {link_id, provider} ->
        if check_auth_method(resource_for(provider), auth_method) == :ok,
          do: revoke_link_by_id(link_id)

      nil ->
        :ok
    end
  end

  defp requested_scopes(nil, granted, _resource), do: {:ok, granted}

  defp requested_scopes(scope, granted, resource) do
    case resource.parse_scopes(scope) do
      {:ok, scopes} ->
        if scopes -- granted == [], do: {:ok, scopes}, else: {:error, :invalid_scope}

      :error ->
        {:error, :invalid_scope}
    end
  end

  # A token request may repeat the grant's resource (RFC 8707 §2.2), never
  # name another. Compared the way authorization requests are, so a resource
  # accepted there is accepted again when the code is redeemed or the token
  # refreshed.
  defp check_resource(nil, _expected), do: :ok

  defp check_resource(resource, expected),
    do: if(resource_is?(resource, expected), do: :ok, else: {:error, :invalid_target})

  defp active_link?(%IdentityLink{revoked_at: nil, inserted_at: inserted_at}) do
    DateTime.diff(DateTime.utc_now(), inserted_at) < @refresh_token_ttl
  end

  defp active_link?(_), do: false

  # Issues an access token and returns the token response.
  defp issue_access_token(%IdentityLink{} = link, scopes, dpop_jkt) do
    token = random_token("ppa_")

    Repo.insert!(%AccessToken{
      token_hash: hash(token),
      identity_link_id: link.id,
      scopes: scopes,
      dpop_jkt: dpop_jkt,
      expires_at: in_seconds(@access_token_ttl)
    })

    %{
      "access_token" => token,
      "token_type" => if(dpop_jkt, do: "DPoP", else: "Bearer"),
      "expires_in" => @access_token_ttl,
      "scope" => Enum.join(scopes, " ")
    }
  end

  @doc """
  Revocation (RFC 7009). Revoking a refresh token revokes its link, which
  also invalidates every access token issued under it. Unknown tokens and
  tokens of other clients succeed without effect, as RFC 7009 §2.2 asks.
  """
  def revoke_token(client_id, token) when is_binary(token) do
    hash = hash(token)

    link_id =
      Repo.one(
        from l in IdentityLink,
          where: l.refresh_token_hash == ^hash and l.subject == ^client_id,
          select: l.id
      ) ||
        Repo.one(
          from t in AccessToken,
            join: l in assoc(t, :identity_link),
            where: t.token_hash == ^hash and l.subject == ^client_id,
            select: l.id
        )

    if link_id, do: revoke_link_by_id(link_id)
    :ok
  end

  def revoke_token(_client_id, _token), do: :ok

  defp revoke_link_by_id(link_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(from(l in IdentityLink, where: l.id == ^link_id and is_nil(l.revoked_at)),
      set: [revoked_at: now, updated_at: now]
    )

    :ok
  end

  ## Protected resources

  @doc """
  Looks up an access token for the resource whose links have `provider`. It
  is valid only while unexpired and while its link is active, so revoking the
  link takes effect on the next request. A token issued for one resource is
  invalid at every other. `dpop_jkt` is the key a DPoP-bound token is bound
  to, or nil.
  """
  def authenticate_access_token(token, provider) when is_binary(token) do
    now = DateTime.utc_now()

    query =
      from t in AccessToken,
        join: l in assoc(t, :identity_link),
        where:
          t.token_hash == ^hash(token) and t.expires_at > ^now and is_nil(l.revoked_at) and
            l.provider == ^provider,
        preload: [identity_link: {l, [:identity, :approved_by_user]}]

    case Repo.one(query) do
      # A blocked client's tokens stop at once, not when they expire.
      %AccessToken{identity_link: link} = access_token ->
        if link.subject in config(:blocked_clients, []) do
          {:error, :invalid_token}
        else
          touch_link(link)
          {:ok, %{link: link, scopes: access_token.scopes, dpop_jkt: access_token.dpop_jkt}}
        end

      nil ->
        {:error, :invalid_token}
    end
  end

  def authenticate_access_token(_token, _provider), do: {:error, :invalid_token}

  defp touch_link(%IdentityLink{} = link) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    if is_nil(link.last_used_at) or DateTime.diff(now, link.last_used_at) > 60 do
      Repo.update_all(from(l in IdentityLink, where: l.id == ^link.id), set: [last_used_at: now])
    end
  end

  ## Metadata

  @doc """
  Protected resource metadata (RFC 9728 §2) for `resource`, or nil while it
  is off.
  """
  def protected_resource_metadata(resource) do
    if resource.enabled?() do
      Map.merge(
        %{
          resource: resource.resource(),
          authorization_servers: [issuer()],
          scopes_supported: resource.scope_names()
        },
        extra(resource, :protected_resource_metadata)
      )
    end
  end

  @doc "Authorization server metadata (RFC 8414) for the issuer and its enabled resources."
  def authorization_server_metadata do
    issuer = issuer()
    resources = enabled_resources()
    public? = public_clients?()
    # Public clients (`none`) and registration are on when a resource takes them.
    auth_methods = if public?, do: ["none", "private_key_jwt"], else: ["private_key_jwt"]

    resources
    |> Enum.map(&extra(&1, :authorization_server_metadata))
    |> Enum.reduce(
      %{
        issuer: issuer,
        authorization_endpoint: issuer <> "/oauth/authorize",
        token_endpoint: issuer <> "/oauth/token",
        revocation_endpoint: issuer <> "/oauth/revoke",
        registration_endpoint: if(public?, do: issuer <> "/oauth/register"),
        response_types_supported: ["code"],
        grant_types_supported: ["authorization_code", "refresh_token"],
        code_challenge_methods_supported: ["S256"],
        token_endpoint_auth_methods_supported: auth_methods,
        token_endpoint_auth_signing_alg_values_supported: ["ES256", "PS384", "RS256"],
        revocation_endpoint_auth_methods_supported: auth_methods,
        revocation_endpoint_auth_signing_alg_values_supported: ["ES256", "PS384", "RS256"],
        authorization_response_iss_parameter_supported: true,
        client_id_metadata_document_supported: true,
        scopes_supported: Enum.flat_map(resources, & &1.scope_names()),
        protected_resources: Enum.map(resources, & &1.resource())
      },
      &Map.merge(&2, &1)
    )
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp extra(resource, callback) do
    if function_exported?(resource, callback, 0), do: apply(resource, callback, []), else: %{}
  end

  ## Owner management

  @doc "Active and revoked links the user approved, newest first."
  def list_links_for(%User{id: user_id}) do
    Repo.all(
      from l in IdentityLink,
        where: l.approved_by_user_id == ^user_id,
        order_by: [desc: l.inserted_at],
        preload: [:identity]
    )
  end

  @doc "The owner revokes a link. Unknown and unowned IDs return the same error."
  def revoke_link(%User{id: user_id}, id) do
    with {link_id, ""} <- Integer.parse(to_string(id)),
         %IdentityLink{} <-
           Repo.one(
             from l in IdentityLink, where: l.id == ^link_id and l.approved_by_user_id == ^user_id
           ) do
      revoke_link_by_id(link_id)
    else
      _ -> {:error, :not_found}
    end
  end

  ## Helpers

  defp random_token(prefix),
    do: prefix <> (:crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false))

  defp hash(value), do: :crypto.hash(:sha256, value)

  defp in_seconds(seconds),
    do: DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.truncate(:second)

  defp expect(true), do: :ok
  defp expect(_), do: :error
end
