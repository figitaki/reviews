defmodule ReviewsWeb.OAuthTest do
  @moduledoc """
  The OAuth issuer over HTTP, with the test resources in
  `Reviews.OAuthTestResource`: discovery, consent, the agents-only rule, the
  token endpoint, refresh rotation, revocation, dynamic registration, and
  `private_key_jwt`. Most tests are the cases that must fail.
  """
  use ReviewsWeb.ConnCase, async: false

  import Ecto.Query

  alias Reviews.Accounts
  alias Reviews.Accounts.IdentityLink
  alias Reviews.OAuth
  alias Reviews.OAuth.{AccessToken, AuthorizationCode}
  alias Reviews.OAuthTestClient, as: Client
  alias Reviews.OAuthTestClient.Fetcher
  alias Reviews.Repo

  @issuer "https://reviews.test"
  @resource "https://reviews.test/api/test"
  @all_scopes ["test:read", "test:write"]
  @keys_resource "https://reviews.test/api/keys"

  setup do
    owner = user_fixture("carey")

    {:ok, agent} =
      Accounts.create_agent_identity(owner, %{display_name: "Claude", handle: "claude"})

    %{owner: owner, agent: agent, app: public_client()}
  end

  # A public client with a client metadata document, as claude.ai publishes it.
  defp public_client do
    n = System.unique_integer([:positive])
    client_id = "https://app#{n}.example/oauth/client-metadata"
    redirect_uri = "https://app#{n}.example/api/auth_callback"

    Fetcher.setup()

    Fetcher.put(client_id, %{
      "client_id" => client_id,
      "client_name" => "App",
      "redirect_uris" => [redirect_uri],
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none"
    })

    %{client_id: client_id, redirect_uri: redirect_uri}
  end

  defp user_fixture(name) do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: "#{name}-#{System.unique_integer([:positive])}"
      })

    {:ok, _human} = Accounts.ensure_human_identity(user)
    user
  end

  defp authorize_params(client, challenge, extra \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client.client_id,
        "redirect_uri" => client.redirect_uri,
        "state" => "st_9",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "resource" => @resource
      },
      extra
    )
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  # The owner approves on the consent page. Returns the redirect's query.
  defp approve(client, user, identity, extra \\ %{}, granted \\ @all_scopes) do
    {verifier, challenge} = Client.pkce()

    conn =
      build_conn()
      |> init_test_session(current_user_id: user.id)
      |> post(
        ~p"/oauth/authorize",
        authorize_params(client, challenge, extra)
        |> Map.merge(%{
          "decision" => "approve",
          "identity_id" => to_string(identity.id),
          "granted_scopes" => granted
        })
      )

    {redirect_query(conn), verifier}
  end

  defp redirect_query(conn) do
    location = redirected_to(conn, 302)
    URI.decode_query(URI.parse(location).query || "")
  end

  defp token(params), do: build_conn() |> post(~p"/oauth/token", params)

  defp exchange(client, code, verifier, extra \\ %{}) do
    token(
      Map.merge(
        %{
          "grant_type" => "authorization_code",
          "client_id" => client.client_id,
          "code" => code,
          "redirect_uri" => client.redirect_uri,
          "code_verifier" => verifier,
          "resource" => @resource
        },
        extra
      )
    )
  end

  defp sign_in(client, user, identity, granted \\ @all_scopes) do
    {%{"code" => code}, verifier} = approve(client, user, identity, %{}, granted)
    json_response(exchange(client, code, verifier), 200)
  end

  defp refresh(client, refresh_token) do
    token(%{
      "grant_type" => "refresh_token",
      "client_id" => client.client_id,
      "refresh_token" => refresh_token
    })
  end

  # Whether the resource `provider` names accepts the access token.
  defp valid?(token, provider \\ "test"),
    do: match?({:ok, _}, OAuth.authenticate_access_token(token, provider))

  # A client with keys signs in to the keys-only resource at the issuer's root.
  defp keys_sign_in(client, user, identity, extra \\ %{}) do
    {verifier, challenge} = Client.pkce()

    conn =
      build_conn()
      |> init_test_session(current_user_id: user.id)
      |> post(
        ~p"/oauth/authorize",
        Map.merge(
          %{
            "response_type" => "code",
            "client_id" => client.client_id,
            "redirect_uri" => client.redirect_uri,
            "scope" => "keys:write",
            "code_challenge" => challenge,
            "code_challenge_method" => "S256",
            "decision" => "approve",
            "identity_id" => to_string(identity.id),
            "granted_scopes" => ["keys:write"]
          },
          extra
        )
      )

    %{"code" => code} = redirect_query(conn)

    token(
      Map.merge(Client.client_auth(client), %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => client.redirect_uri,
        "code_verifier" => verifier
      })
      |> Map.merge(Map.take(extra, ["resource"]))
    )
  end

  describe "discovery" do
    test "protected resource and issuer metadata lead to the sign-in endpoints", %{conn: conn} do
      resource =
        conn |> get("/.well-known/oauth-protected-resource/api/test") |> json_response(200)

      assert resource["resource"] == @resource
      assert resource["resource_name"] == "Test API"
      assert resource["authorization_servers"] == [@issuer]
      assert resource["scopes_supported"] == @all_scopes

      keys =
        build_conn()
        |> get("/.well-known/oauth-protected-resource/api/keys")
        |> json_response(200)

      assert keys["resource"] == @keys_resource
      assert keys["scopes_supported"] == ["keys:write"]

      assert build_conn()
             |> get("/.well-known/oauth-protected-resource/nope")
             |> json_response(404)

      assert get_resp_header(
               build_conn() |> get("/.well-known/oauth-protected-resource/api/test"),
               "access-control-allow-origin"
             ) == ["*"]

      issuer =
        build_conn() |> get("/.well-known/oauth-authorization-server") |> json_response(200)

      assert issuer["issuer"] == @issuer
      assert issuer["authorization_endpoint"] == @issuer <> "/oauth/authorize"
      assert issuer["token_endpoint"] == @issuer <> "/oauth/token"
      assert issuer["code_challenge_methods_supported"] == ["S256"]
      assert issuer["token_endpoint_auth_methods_supported"] == ["none", "private_key_jwt"]
      assert issuer["client_id_metadata_document_supported"] == true
      assert issuer["authorization_response_iss_parameter_supported"] == true
      assert issuer["registration_endpoint"] == @issuer <> "/oauth/register"
      assert Enum.all?(["keys:write" | @all_scopes], &(&1 in issuer["scopes_supported"]))
      assert @keys_resource in issuer["protected_resources"]
      assert @resource in issuer["protected_resources"]
      assert issuer["keys_resource_extra"] == true
    end

    test "with no resource taking public clients, the issuer offers no public clients or registration" do
      previous = Application.get_env(:reviews, Reviews.OAuthTestResource)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:reviews, Reviews.OAuthTestResource, previous),
          else: Application.delete_env(:reviews, Reviews.OAuthTestResource)
      end)

      Application.put_env(:reviews, Reviews.OAuthTestResource, enabled: false)

      issuer =
        build_conn() |> get("/.well-known/oauth-authorization-server") |> json_response(200)

      assert issuer["token_endpoint_auth_methods_supported"] == ["private_key_jwt"]
      refute Map.has_key?(issuer, "registration_endpoint")
      refute @resource in issuer["protected_resources"]

      assert build_conn()
             |> get("/.well-known/oauth-protected-resource/api/test")
             |> json_response(404)

      assert build_conn()
             |> put_req_header("content-type", "application/json")
             |> post(
               ~p"/oauth/register",
               JSON.encode!(%{"redirect_uris" => ["https://a.example/cb"]})
             )
             |> json_response(404)
    end

    test "a browser client's preflight to the token endpoint is answered" do
      conn = build_conn() |> options("/oauth/token")
      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end

  describe "sign-in with a client metadata document" do
    test "the consent page names the verified domain and offers only the owner's agents", ctx do
      {_verifier, challenge} = Client.pkce()

      html =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> get(~p"/oauth/authorize", authorize_params(ctx.app, challenge))
        |> html_response(200)

      doc = LazyHTML.from_document(html)
      host = URI.parse(ctx.app.client_id).host

      assert doc |> LazyHTML.query("#poppy-consent-client") |> LazyHTML.text() =~ host
      assert html =~ "Let this test app in?"
      human = Accounts.human_identity_for(ctx.owner)

      offered =
        doc
        |> LazyHTML.query("#poppy-consent-identity input[name=identity_id]")
        |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> hd()))

      assert offered == [to_string(ctx.agent.id)]
      refute doc |> LazyHTML.query("#poppy-identity-#{human.id}") |> Enum.any?()

      scopes =
        doc
        |> LazyHTML.query("#poppy-consent-scopes input")
        |> Enum.map(&(&1 |> LazyHTML.attribute("value") |> hd()))

      assert scopes == @all_scopes

      assert doc
             |> LazyHTML.query("input[name=resource]")
             |> LazyHTML.attribute("value") == [@resource]
    end

    test "signed out, the authorize page asks for GitHub sign-in and returns to it", ctx do
      {_verifier, challenge} = Client.pkce()
      params = authorize_params(ctx.app, challenge)

      doc =
        build_conn()
        |> get(~p"/oauth/authorize", params)
        |> html_response(200)
        |> LazyHTML.from_document()

      [href] = doc |> LazyHTML.query("#poppy-sign-in-github") |> LazyHTML.attribute("href")
      %URI{path: "/auth/github", query: query} = URI.parse(href)
      assert "/oauth/authorize?" <> _ = return_to = URI.decode_query(query)["return_to"]
      assert URI.decode_query(URI.parse(return_to).query)["client_id"] == ctx.app.client_id
    end

    test "the app acts as the identity the owner chose, with the scopes granted", ctx do
      {query, verifier} = approve(ctx.app, ctx.owner, ctx.agent, %{}, ["test:read"])
      assert %{"code" => code, "state" => "st_9", "iss" => @issuer} = query

      body = exchange(ctx.app, code, verifier) |> json_response(200)

      assert %{"token_type" => "Bearer", "expires_in" => 3600, "refresh_token" => _} = body
      assert body["scope"] == "test:read"
      assert get_resp_header(exchange(ctx.app, "x", verifier), "cache-control") == ["no-store"]

      assert {:ok, %{link: link, scopes: ["test:read"]}} =
               OAuth.authenticate_access_token(body["access_token"], "test")

      assert link.identity_id == ctx.agent.id
      assert link.provider == "test"
      assert link.subject == ctx.app.client_id
      assert [%{id: id}] = OAuth.list_links_for(ctx.owner)
      assert id == link.id
    end
  end

  describe "refresh tokens" do
    test "rotate, and presenting a replaced one revokes the grant", ctx do
      first = sign_in(ctx.app, ctx.owner, ctx.agent)

      second = refresh(ctx.app, first["refresh_token"]) |> json_response(200)
      assert second["refresh_token"] != first["refresh_token"]
      assert valid?(second["access_token"])

      # The replaced token is refused and ends the grant, so the stolen copy
      # and the legitimate one both stop working.
      assert %{"error" => "invalid_grant"} =
               refresh(ctx.app, first["refresh_token"]) |> json_response(400)

      refute valid?(second["access_token"])

      assert %{"error" => "invalid_grant"} =
               refresh(ctx.app, second["refresh_token"]) |> json_response(400)
    end

    test "presenting any earlier one revokes the grant, not only the last", ctx do
      r0 = sign_in(ctx.app, ctx.owner, ctx.agent)
      r1 = refresh(ctx.app, r0["refresh_token"]) |> json_response(200)
      r2 = refresh(ctx.app, r1["refresh_token"]) |> json_response(200)

      assert %{"error" => "invalid_grant"} =
               refresh(ctx.app, r0["refresh_token"]) |> json_response(400)

      refute valid?(r2["access_token"])

      assert %{"error" => "invalid_grant"} =
               refresh(ctx.app, r2["refresh_token"]) |> json_response(400)
    end

    test "don't rotate for a resource that doesn't ask for it", ctx do
      client = Client.new()
      first = keys_sign_in(client, ctx.owner, ctx.agent) |> json_response(200)

      params = %{"grant_type" => "refresh_token", "refresh_token" => first["refresh_token"]}

      second = token(Map.merge(Client.client_auth(client), params)) |> json_response(200)
      refute Map.has_key?(second, "refresh_token")
      assert valid?(second["access_token"], "keys")

      assert token(Map.merge(Client.client_auth(client), params)) |> json_response(200)
      assert valid?(second["access_token"], "keys")
    end

    test "can narrow scopes but never widen them", ctx do
      tokens = sign_in(ctx.app, ctx.owner, ctx.agent, ["test:read"])

      assert %{"error" => "invalid_scope"} =
               token(%{
                 "grant_type" => "refresh_token",
                 "client_id" => ctx.app.client_id,
                 "refresh_token" => tokens["refresh_token"],
                 "scope" => "test:read test:write"
               })
               |> json_response(400)

      tokens = sign_in(ctx.app, ctx.owner, ctx.agent)

      narrowed =
        token(%{
          "grant_type" => "refresh_token",
          "client_id" => ctx.app.client_id,
          "refresh_token" => tokens["refresh_token"],
          "scope" => "test:read"
        })
        |> json_response(200)

      assert narrowed["scope"] == "test:read"
    end

    test "belong to the client they were issued to", ctx do
      tokens = sign_in(ctx.app, ctx.owner, ctx.agent)
      other = public_client()

      assert %{"error" => "invalid_grant"} =
               refresh(other, tokens["refresh_token"]) |> json_response(400)
    end
  end

  describe "rejected authorization requests" do
    test "an unregistered redirect URI gets an error page, not a redirect", ctx do
      {_verifier, challenge} = Client.pkce()

      for uri <- ["https://evil.example/cb", ctx.app.redirect_uri <> "/extra"] do
        conn =
          build_conn()
          |> init_test_session(current_user_id: ctx.owner.id)
          |> get(
            ~p"/oauth/authorize",
            authorize_params(ctx.app, challenge, %{"redirect_uri" => uri})
          )

        assert html_response(conn, 400) =~ "didn&#39;t register"
      end
    end

    test "another resource, an unknown scope, or no PKCE redirect with an error and iss", ctx do
      {_verifier, challenge} = Client.pkce()

      cases = [
        {%{"resource" => "https://evil.example/api/test"}, "invalid_target"},
        {%{"scope" => "test:read admin"}, "invalid_scope"},
        {%{"code_challenge_method" => "plain"}, "invalid_request"},
        {%{"response_type" => "token"}, "unsupported_response_type"},
        # A public client can't get tokens for a resource that needs keys.
        {%{"resource" => nil, "scope" => "keys:write"}, "unauthorized_client"},
        {%{"resource" => @keys_resource}, "unauthorized_client"}
      ]

      for {extra, error} <- cases do
        conn =
          build_conn()
          |> init_test_session(current_user_id: ctx.owner.id)
          |> get(~p"/oauth/authorize", authorize_params(ctx.app, challenge, extra))

        assert %{"error" => ^error, "iss" => @issuer, "state" => "st_9"} = redirect_query(conn)
      end
    end

    test "an identity of another account is refused", ctx do
      stranger = user_fixture("stranger")
      {:ok, theirs} = Accounts.create_agent_identity(stranger, %{display_name: "X", handle: "x"})
      {_verifier, challenge} = Client.pkce()

      conn =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> post(
          ~p"/oauth/authorize",
          authorize_params(ctx.app, challenge)
          |> Map.merge(%{
            "decision" => "approve",
            "identity_id" => to_string(theirs.id),
            "granted_scopes" => @all_scopes
          })
        )

      assert html_response(conn, 200) =~ "Choose one of your"
      assert Repo.aggregate(IdentityLink, :count) == 0
    end

    test "the owner's own human identity is refused, even posted by hand", ctx do
      human = Accounts.human_identity_for(ctx.owner)
      {_verifier, challenge} = Client.pkce()

      conn =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> post(
          ~p"/oauth/authorize",
          authorize_params(ctx.app, challenge)
          |> Map.merge(%{
            "decision" => "approve",
            "identity_id" => to_string(human.id),
            "granted_scopes" => @all_scopes
          })
        )

      assert html_response(conn, 200) =~ "Choose one of your agent identities"
      assert get_resp_header(conn, "location") == []
      assert Repo.aggregate(AuthorizationCode, :count) == 0
    end

    test "no granted scope, or only ones the request lacks, is refused", ctx do
      {_verifier, challenge} = Client.pkce()

      for granted <- [[], ["admin"]] do
        conn =
          build_conn()
          |> init_test_session(current_user_id: ctx.owner.id)
          |> post(
            ~p"/oauth/authorize",
            authorize_params(ctx.app, challenge, %{"scope" => "test:read"})
            |> Map.merge(%{
              "decision" => "approve",
              "identity_id" => to_string(ctx.agent.id),
              "granted_scopes" => granted
            })
          )

        assert html_response(conn, 200) =~ "at least one permission"
      end

      assert Repo.aggregate(AuthorizationCode, :count) == 0
    end

    test "an owner with no agents is asked to create one instead of approving", ctx do
      owner = user_fixture("no-agents")
      {_verifier, challenge} = Client.pkce()

      doc =
        build_conn()
        |> init_test_session(current_user_id: owner.id)
        |> get(~p"/oauth/authorize", authorize_params(ctx.app, challenge))
        |> html_response(200)
        |> LazyHTML.from_document()

      assert doc |> LazyHTML.query("#poppy-consent-no-agents") |> Enum.any?()
      refute doc |> LazyHTML.query("#poppy-consent-form") |> Enum.any?()
    end

    test "approving signed out is refused", ctx do
      {_verifier, challenge} = Client.pkce()

      conn =
        build_conn()
        |> post(
          ~p"/oauth/authorize",
          authorize_params(ctx.app, challenge)
          |> Map.merge(%{"decision" => "approve", "identity_id" => to_string(ctx.agent.id)})
        )

      assert html_response(conn, 401) =~ "session ended"
    end

    test "denying sends access_denied back", ctx do
      {_verifier, challenge} = Client.pkce()

      conn =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> post(
          ~p"/oauth/authorize",
          Map.put(authorize_params(ctx.app, challenge), "decision", "deny")
        )

      assert %{"error" => "access_denied", "iss" => @issuer} = redirect_query(conn)
    end
  end

  describe "rejected token requests" do
    test "a wrong PKCE verifier", ctx do
      {%{"code" => code}, _verifier} = approve(ctx.app, ctx.owner, ctx.agent)
      {other_verifier, _} = Client.pkce()

      assert %{"error" => "invalid_grant"} =
               exchange(ctx.app, code, other_verifier) |> json_response(400)
    end

    test "a reused code, which also revokes the tokens the first use got", ctx do
      {%{"code" => code}, verifier} = approve(ctx.app, ctx.owner, ctx.agent)
      tokens = exchange(ctx.app, code, verifier) |> json_response(200)

      assert %{"error" => "invalid_grant"} =
               exchange(ctx.app, code, verifier) |> json_response(400)

      refute valid?(tokens["access_token"])
    end

    test "an expired code", ctx do
      {%{"code" => code}, verifier} = approve(ctx.app, ctx.owner, ctx.agent)
      Repo.update_all(AuthorizationCode, set: [expires_at: ~U[2020-01-01 00:00:00Z]])

      assert %{"error" => "invalid_grant"} =
               exchange(ctx.app, code, verifier) |> json_response(400)
    end

    test "a code redeemed by another client, or at another redirect URI", ctx do
      {%{"code" => code}, verifier} = approve(ctx.app, ctx.owner, ctx.agent)
      other = public_client()

      assert %{"error" => "invalid_grant"} = exchange(other, code, verifier) |> json_response(400)

      {%{"code" => code}, verifier} = approve(ctx.app, ctx.owner, ctx.agent)

      assert %{"error" => "invalid_grant"} =
               exchange(ctx.app, code, verifier, %{
                 "redirect_uri" => ctx.app.redirect_uri <> "x"
               })
               |> json_response(400)
    end

    test "another resource than the code's", ctx do
      {%{"code" => code}, verifier} = approve(ctx.app, ctx.owner, ctx.agent)

      assert %{"error" => "invalid_target"} =
               exchange(ctx.app, code, verifier, %{"resource" => @keys_resource})
               |> json_response(400)
    end

    test "client authentication the client can't use", ctx do
      {%{"code" => code}, verifier} = approve(ctx.app, ctx.owner, ctx.agent)

      # Reviews issues no secrets, an unknown client is unknown, and a client
      # whose metadata requires private_key_jwt must send an assertion.
      keyed = Client.new()

      for extra <- [
            %{"client_secret" => "guess"},
            %{"client_id" => "rvc_unknown"},
            %{"client_id" => keyed.client_id},
            %{"client_id" => nil}
          ] do
        assert %{"error" => "invalid_client"} =
                 exchange(ctx.app, code, verifier, extra)
                 |> json_response(401)
      end

      # None of those used up the code.
      assert exchange(ctx.app, code, verifier) |> json_response(200)
    end

    test "an unknown grant type", ctx do
      assert %{"error" => "unsupported_grant_type"} =
               token(%{"grant_type" => "password", "client_id" => ctx.app.client_id})
               |> json_response(400)
    end
  end

  describe "access tokens" do
    test "an expired token is refused", ctx do
      tokens = sign_in(ctx.app, ctx.owner, ctx.agent)
      Repo.update_all(AccessToken, set: [expires_at: ~U[2020-01-01 00:00:00Z]])

      refute valid?(tokens["access_token"])
    end

    test "disconnecting stops the token on its next use", ctx do
      tokens = sign_in(ctx.app, ctx.owner, ctx.agent)
      assert valid?(tokens["access_token"])

      [link] = OAuth.list_links_for(ctx.owner)
      assert {:error, :not_found} = OAuth.revoke_link(user_fixture("other"), link.id)
      :ok = OAuth.revoke_link(ctx.owner, link.id)

      refute valid?(tokens["access_token"])
      assert refresh(ctx.app, tokens["refresh_token"]) |> json_response(400)
    end

    test "revoking the refresh token at the revocation endpoint ends the grant", ctx do
      tokens = sign_in(ctx.app, ctx.owner, ctx.agent)
      other = public_client()

      # Another client's revocation succeeds without effect (RFC 7009 §2.2).
      conn =
        build_conn()
        |> post(~p"/oauth/revoke", %{
          "client_id" => other.client_id,
          "token" => tokens["refresh_token"]
        })

      assert conn.status == 200
      assert valid?(tokens["access_token"])

      conn =
        build_conn()
        |> post(~p"/oauth/revoke", %{
          "client_id" => ctx.app.client_id,
          "token" => tokens["refresh_token"]
        })

      assert conn.status == 200
      refute valid?(tokens["access_token"])
    end

    test "a token issued for one resource is refused by another", ctx do
      tokens = sign_in(ctx.app, ctx.owner, ctx.agent)
      assert valid?(tokens["access_token"], "test")
      refute valid?(tokens["access_token"], "keys")

      keys = keys_sign_in(Client.new(), ctx.owner, ctx.agent) |> json_response(200)
      assert valid?(keys["access_token"], "keys")
      refute valid?(keys["access_token"], "test")
    end

    test "blocking the client stops its access tokens at once", ctx do
      tokens = sign_in(ctx.app, ctx.owner, ctx.agent)
      assert valid?(tokens["access_token"])

      previous = Application.get_env(:reviews, OAuth)
      on_exit(fn -> Application.put_env(:reviews, OAuth, previous) end)

      Application.put_env(
        :reviews,
        OAuth,
        Keyword.put(previous, :blocked_clients, [ctx.app.client_id])
      )

      refute valid?(tokens["access_token"])

      {_verifier, challenge} = Client.pkce()

      conn =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> get(~p"/oauth/authorize", authorize_params(ctx.app, challenge))

      assert html_response(conn, 400) =~ "couldn&#39;t verify"
    end

    test "a resource with a trailing slash is accepted at authorize and at token", ctx do
      assert keys_sign_in(Client.new(), ctx.owner, ctx.agent, %{
               "resource" => @keys_resource <> "/"
             })
             |> json_response(200)
    end
  end

  describe "dynamic client registration" do
    test "registers a public client that signs in like any other", ctx do
      body =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          ~p"/oauth/register",
          JSON.encode!(%{
            "client_name" => "MCP Inspector",
            "redirect_uris" => ["http://localhost:6274/oauth/callback"],
            "grant_types" => ["authorization_code", "refresh_token"],
            "token_endpoint_auth_method" => "none"
          })
        )
        |> json_response(201)

      assert %{"client_id" => "rvc_" <> _, "token_endpoint_auth_method" => "none"} = body

      client = %{
        client_id: body["client_id"],
        redirect_uri: "http://localhost:6274/oauth/callback"
      }

      # The page can't vouch for a registered client, and warns about loopback.
      {_verifier, challenge} = Client.pkce()

      html =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> get(~p"/oauth/authorize", authorize_params(client, challenge))
        |> html_response(200)

      assert html =~ "This app registered itself"
      assert html =~ ~s(id="poppy-consent-loopback")

      # A bad request from a registered client gets a page, not a redirect: anyone
      # can register any redirect URI, so a redirect here would be an open one.
      conn =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> get(~p"/oauth/authorize", authorize_params(client, challenge, %{"scope" => "admin"}))

      assert html_response(conn, 400) =~ "can&#39;t accept"

      # Loopback redirects match on any port (RFC 8252 §7.3).
      on_other_port = %{client | redirect_uri: "http://localhost:51234/oauth/callback"}
      tokens = sign_in(on_other_port, ctx.owner, ctx.agent)
      assert valid?(tokens["access_token"])
    end

    test "refuses redirect URIs a browser could be tricked by, and confidential clients" do
      register = fn body ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/oauth/register", JSON.encode!(body))
      end

      for uri <- [
            "javascript:alert(1)",
            "http://evil.example/cb",
            "https://ok.example/cb#frag",
            "data:text/html,hi"
          ] do
        assert %{"error" => "invalid_redirect_uri"} =
                 register.(%{"redirect_uris" => [uri]}) |> json_response(400)
      end

      assert %{"error" => "invalid_redirect_uri"} = register.(%{}) |> json_response(400)

      assert %{"error" => "invalid_client_metadata"} =
               register.(%{
                 "redirect_uris" => ["https://ok.example/cb"],
                 "token_endpoint_auth_method" => "client_secret_basic"
               })
               |> json_response(400)

      # An app's private-use scheme is fine (RFC 8252 §7.1).
      assert register.(%{"redirect_uris" => ["cursor://anysphere.cursor/oauth/callback"]})
             |> json_response(201)
    end
  end

  describe "private_key_jwt clients" do
    setup do
      rsa = Client.rsa_key("cimd-test", "RS256")
      client = Client.new()
      client = %{client | root: rsa, rsa: rsa}

      Client.publish(
        client,
        %{"token_endpoint_auth_methods_supported" => ["none", "private_key_jwt"]},
        [rsa.public]
      )

      previous = Application.get_env(:reviews, OAuth)
      on_exit(fn -> Application.put_env(:reviews, OAuth, previous) end)

      Application.put_env(
        :reviews,
        OAuth,
        Keyword.put(previous, :token_endpoint_audience_clients, [client.client_id])
      )

      %{keyed: client}
    end

    test "an RS256 assertion addressed to a listed client's token endpoint signs in", ctx do
      {%{"code" => code}, verifier} = approve(ctx.keyed, ctx.owner, ctx.agent)

      params =
        Map.merge(Client.client_auth(ctx.keyed, aud: @issuer <> "/oauth/token"), %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => ctx.keyed.redirect_uri,
          "code_verifier" => verifier,
          "resource" => @resource
        })

      tokens = token(params) |> json_response(200)
      assert valid?(tokens["access_token"])
    end

    test "a bad signature is refused", ctx do
      {%{"code" => code}, verifier} = approve(ctx.keyed, ctx.owner, ctx.agent)

      params =
        ctx.keyed
        |> Client.client_auth(aud: @issuer <> "/oauth/token")
        |> Map.update!("client_assertion", &tamper/1)
        |> Map.merge(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => ctx.keyed.redirect_uri,
          "code_verifier" => verifier
        })

      assert %{"error" => "invalid_client"} = token(params) |> json_response(401)
    end
  end

  defp tamper(jwt) do
    [header, claims, sig] = String.split(jwt, ".")
    {:ok, bytes} = Base.url_decode64(sig, padding: false)
    <<first, rest::binary>> = bytes

    Enum.join(
      [
        header,
        claims,
        Base.url_encode64(<<Bitwise.bxor(first, 1), rest::binary>>, padding: false)
      ],
      "."
    )
  end

  test "codes and refresh tokens are stored only as hashes", ctx do
    tokens = sign_in(ctx.app, ctx.owner, ctx.agent)
    [link] = Repo.all(from l in IdentityLink, where: l.provider == "test")
    refute link.refresh_token_hash == tokens["refresh_token"]
    assert link.refresh_token_hash == :crypto.hash(:sha256, tokens["refresh_token"])
  end
end
