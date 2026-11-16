defmodule ReviewsWeb.MCPOAuthTest do
  @moduledoc """
  OAuth for `/mcp` over HTTP (issue #109): discovery from a 401, sign-in with
  a client metadata document (Claude), dynamic registration, and
  `private_key_jwt` (ChatGPT), then tool calls as the chosen identity. Most
  tests are the cases that must fail.
  """
  use ReviewsWeb.ConnCase, async: true

  import Ecto.Query

  alias Reviews.Accounts
  alias Reviews.Accounts.IdentityLink
  alias Reviews.OAuth
  alias Reviews.OAuth.{AccessToken, AuthorizationCode, Clients}
  alias Reviews.OAuthTestClient, as: Agent
  alias Reviews.OAuthTestClient.Fetcher
  alias Reviews.Repo
  alias Reviews.Reviews, as: ReviewsContext

  @issuer "https://reviews.test"
  @resource "https://reviews.test/mcp"
  @metadata_url "https://reviews.test/.well-known/oauth-protected-resource/mcp"
  @all_scopes ["reviews:read", "reviews:write", "threads:write"]
  @diff "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"

  setup do
    owner = user_fixture("carey")

    {:ok, agent} =
      Accounts.create_agent_identity(owner, %{display_name: "Claude", handle: "claude"})

    {:ok, %{review: review}} =
      ReviewsContext.create_review_with_initial_patchset(owner, %{
        title: "Connector review",
        description: "Adds OAuth",
        raw_diff: @diff
      })

    %{owner: owner, agent: agent, review: review, claude: claude_client()}
  end

  # A public client with a client metadata document, as claude.ai publishes it.
  defp claude_client do
    n = System.unique_integer([:positive])
    client_id = "https://claude#{n}.example/oauth/mcp-oauth-client-metadata"
    redirect_uri = "https://claude#{n}.example/api/mcp/auth_callback"

    Fetcher.setup()

    Fetcher.put(client_id, %{
      "client_id" => client_id,
      "client_name" => "Claude",
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
  end

  # The owner approves on the consent page. Returns the redirect's query.
  defp approve(client, user, identity, extra \\ %{}, granted \\ @all_scopes) do
    {verifier, challenge} = Agent.pkce()

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

  defp mcp(token, method, params \\ %{}) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    conn = %{build_conn() | host: "localhost"}
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    conn = if name = params["name"], do: put_req_header(conn, "mcp-name", name), else: conn

    conn
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", "2026-07-28")
    |> put_req_header("mcp-method", method)
    |> post(
      "/mcp",
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => method,
        "params" => Map.put(params, "_meta", meta)
      })
    )
  end

  defp call_tool(token, name, args \\ %{}),
    do: mcp(token, "tools/call", %{"name" => name, "arguments" => args})

  defp whoami(token), do: call_tool(token, "reviews_whoami")

  defp challenge(conn) do
    [value] = get_resp_header(conn, "www-authenticate")
    value
  end

  describe "discovery" do
    test "a 401 from /mcp names the protected resource metadata and the scopes" do
      conn = mcp(nil, "tools/list")
      assert conn.status == 401
      value = challenge(conn)
      assert value =~ ~r/^Bearer resource_metadata="#{Regex.escape(@metadata_url)}"/
      assert value =~ ~s(scope="reviews:read reviews:write threads:write")
      refute value =~ "error="

      conn = mcp("ppa_not-a-token", "tools/list")
      assert conn.status == 401
      assert challenge(conn) =~ ~s(resource_metadata="#{@metadata_url}")
      assert challenge(conn) =~ ~s(error="invalid_token")
    end

    test "protected resource and issuer metadata lead to the sign-in endpoints", %{conn: conn} do
      resource =
        conn |> get("/.well-known/oauth-protected-resource/mcp") |> json_response(200)

      assert resource["resource"] == @resource
      assert resource["authorization_servers"] == [@issuer]
      assert resource["scopes_supported"] == @all_scopes

      assert get_resp_header(build_conn() |> get(@metadata_url), "access-control-allow-origin") ==
               ["*"]

      issuer =
        build_conn() |> get("/.well-known/oauth-authorization-server") |> json_response(200)

      assert issuer["issuer"] == @issuer
      assert issuer["code_challenge_methods_supported"] == ["S256"]
      assert issuer["token_endpoint_auth_methods_supported"] == ["none", "private_key_jwt"]
      assert issuer["client_id_metadata_document_supported"] == true
      assert issuer["authorization_response_iss_parameter_supported"] == true
      assert issuer["registration_endpoint"] == @issuer <> "/oauth/register"
      assert Enum.all?(@all_scopes, &(&1 in issuer["scopes_supported"]))
      assert @resource in issuer["protected_resources"]
    end

    test "a browser client's preflight to the token endpoint is answered" do
      conn = build_conn() |> options("/oauth/token")
      assert conn.status == 204
      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end

  describe "sign-in with a client metadata document" do
    test "the consent page names the verified domain and offers only the owner's agents", ctx do
      {_verifier, challenge} = Agent.pkce()

      html =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> get(~p"/oauth/authorize", authorize_params(ctx.claude, challenge))
        |> html_response(200)

      doc = LazyHTML.from_document(html)
      host = URI.parse(ctx.claude.client_id).host

      assert doc |> LazyHTML.query("#poppy-consent-client") |> LazyHTML.text() =~ host
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

    test "the connector acts as the identity the owner chose, with the scopes granted", ctx do
      {query, verifier} = approve(ctx.claude, ctx.owner, ctx.agent)
      assert %{"code" => code, "state" => "st_9", "iss" => @issuer} = query

      body = exchange(ctx.claude, code, verifier) |> json_response(200)

      assert %{"token_type" => "Bearer", "expires_in" => 3600, "refresh_token" => _} = body
      assert body["scope"] == Enum.join(@all_scopes, " ")

      result = whoami(body["access_token"]) |> json_response(200)

      assert %{"identity" => %{"handle" => "claude", "kind" => "agent"}} =
               result["result"]["structuredContent"]

      assert result["result"]["structuredContent"]["scopes"] == @all_scopes

      [link] = OAuth.list_links_for(ctx.owner)
      assert link.provider == "mcp"
      assert link.subject == ctx.claude.client_id
    end

    test "a read-only grant hides and refuses the write tools", ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent, ["reviews:read"])

      tools = mcp(tokens["access_token"], "tools/list") |> json_response(200)
      names = Enum.map(tools["result"]["tools"], & &1["name"])
      assert "reviews_get_review" in names
      refute "reviews_post_comment" in names

      conn =
        call_tool(tokens["access_token"], "reviews_post_comment", %{
          "review" => ctx.review.slug,
          "body" => "hi",
          "path" => "foo",
          "line" => 1
        })

      assert conn.status == 403
      assert challenge(conn) =~ ~s(error="insufficient_scope")
      assert challenge(conn) =~ ~s(resource_metadata="#{@metadata_url}")
      assert challenge(conn) =~ ~s(scope="threads:write")
    end

    test "an access token reads only the reviews its account owns", ctx do
      stranger = user_fixture("stranger")

      {:ok, %{review: foreign}} =
        ReviewsContext.create_review_with_initial_patchset(stranger, %{
          title: "Not yours",
          raw_diff: @diff
        })

      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent)

      result =
        call_tool(tokens["access_token"], "reviews_get_review", %{"review" => foreign.slug})
        |> json_response(200)

      assert result["result"]["isError"] == true

      fetched =
        call_tool(tokens["access_token"], "fetch", %{"id" => foreign.slug}) |> json_response(200)

      assert fetched["result"]["isError"] == true

      search =
        call_tool(tokens["access_token"], "search", %{"query" => ""}) |> json_response(200)

      ids = Enum.map(search["result"]["structuredContent"]["results"], & &1["id"])
      assert ctx.review.slug in ids
      refute foreign.slug in ids
    end
  end

  describe "search and fetch" do
    test "match the shape ChatGPT's connectors expect", ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent, ["reviews:read"])

      result =
        call_tool(tokens["access_token"], "search", %{"query" => "connector"})
        |> json_response(200)
        |> Map.fetch!("result")

      url = ReviewsWeb.Endpoint.url() <> "/r/" <> ctx.review.slug

      assert result["structuredContent"] == %{
               "results" => [
                 %{"id" => ctx.review.slug, "title" => "Connector review", "url" => url}
               ]
             }

      assert [%{"type" => "text", "text" => text}] = result["content"]
      assert JSON.decode!(text) == result["structuredContent"]

      # LIKE wildcards in the query match only themselves.
      none = call_tool(tokens["access_token"], "search", %{"query" => "%"}) |> json_response(200)
      assert none["result"]["structuredContent"]["results"] == []

      doc =
        call_tool(tokens["access_token"], "fetch", %{"id" => ctx.review.slug})
        |> json_response(200)
        |> get_in(["result", "structuredContent"])

      assert %{"id" => _, "title" => "Connector review", "url" => ^url} = doc
      assert doc["text"] =~ "Adds OAuth"
      assert doc["text"] =~ "Open threads: 0"
      assert doc["metadata"] == %{"revision" => 1, "open_threads" => 0, "complete" => true}
    end

    test "fetch cuts a long review short to fit one result", ctx do
      # Multi-byte text, so the cut must fall between characters.
      long = String.duplicate("Ünïcödé — a long description line ✓\n", 4_000)

      {:ok, %{review: review}} =
        ReviewsContext.create_review_with_initial_patchset(ctx.owner, %{
          title: "Long",
          description: long,
          raw_diff: @diff
        })

      # And open feedback too.
      for _ <- 1..10 do
        {:ok, _} =
          Reviews.Threads.publish_comment(review, ctx.owner, %{
            "file_path" => "foo",
            "side" => "new",
            "body" => String.duplicate("Please rename this ✓ ", 90),
            "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
          })
      end

      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent, ["reviews:read"])
      conn = call_tool(tokens["access_token"], "fetch", %{"id" => review.slug})

      assert byte_size(conn.resp_body) <= 120_000
      doc = conn |> json_response(200) |> get_in(["result", "structuredContent"])
      assert doc["metadata"]["complete"] == false
      assert String.valid?(doc["text"])
      assert doc["text"] =~ "Cut short to fit"
    end

    test "fetch says it is incomplete when the feedback leaves comments out", ctx do
      # One short description, one thread with a comment longer than the
      # feedback text shows: the result fits, but it isn't everything.
      {:ok, _} =
        Reviews.Threads.publish_comment(ctx.review, ctx.owner, %{
          "file_path" => "foo",
          "side" => "new",
          "body" => String.duplicate("x", 3_000),
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
        })

      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent, ["reviews:read"])

      doc =
        call_tool(tokens["access_token"], "fetch", %{"id" => ctx.review.slug})
        |> json_response(200)
        |> get_in(["result", "structuredContent"])

      assert doc["metadata"]["complete"] == false
      assert doc["text"] =~ "reviews_get_thread"
    end

    test "every tool declares readOnlyHint, destructiveHint, and openWorldHint", ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent)
      tools = mcp(tokens["access_token"], "tools/list") |> json_response(200)

      for tool <- tools["result"]["tools"] do
        hints = Map.take(tool["annotations"], ~w(readOnlyHint destructiveHint openWorldHint))
        assert map_size(hints) == 3, tool["name"]
        assert Enum.all?(Map.values(hints), &is_boolean/1), tool["name"]
        assert [%{"type" => "oauth2"}] = tool["_meta"]["securitySchemes"]
      end

      by_name = Map.new(tools["result"]["tools"], &{&1["name"], &1["annotations"]})
      assert by_name["search"]["readOnlyHint"] == true
      assert by_name["fetch"]["readOnlyHint"] == true
      assert by_name["reviews_post_comment"]["readOnlyHint"] == false
    end
  end

  describe "refresh tokens" do
    test "rotate, and presenting a replaced one revokes the grant", ctx do
      first = sign_in(ctx.claude, ctx.owner, ctx.agent)

      second = refresh(ctx.claude, first["refresh_token"]) |> json_response(200)
      assert second["refresh_token"] != first["refresh_token"]
      assert whoami(second["access_token"]).status == 200

      # The replaced token is refused and ends the grant, so the stolen copy
      # and the legitimate one both stop working.
      assert %{"error" => "invalid_grant"} =
               refresh(ctx.claude, first["refresh_token"]) |> json_response(400)

      assert whoami(second["access_token"]).status == 401

      assert %{"error" => "invalid_grant"} =
               refresh(ctx.claude, second["refresh_token"]) |> json_response(400)
    end

    test "presenting any earlier one revokes the grant, not only the last", ctx do
      r0 = sign_in(ctx.claude, ctx.owner, ctx.agent)
      r1 = refresh(ctx.claude, r0["refresh_token"]) |> json_response(200)
      r2 = refresh(ctx.claude, r1["refresh_token"]) |> json_response(200)

      assert %{"error" => "invalid_grant"} =
               refresh(ctx.claude, r0["refresh_token"]) |> json_response(400)

      assert whoami(r2["access_token"]).status == 401

      assert %{"error" => "invalid_grant"} =
               refresh(ctx.claude, r2["refresh_token"]) |> json_response(400)
    end

    test "can narrow scopes but never widen them", ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent, ["reviews:read"])

      assert %{"error" => "invalid_scope"} =
               token(%{
                 "grant_type" => "refresh_token",
                 "client_id" => ctx.claude.client_id,
                 "refresh_token" => tokens["refresh_token"],
                 "scope" => "reviews:read threads:write"
               })
               |> json_response(400)
    end

    test "belong to the client they were issued to", ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent)
      other = claude_client()

      assert %{"error" => "invalid_grant"} =
               refresh(other, tokens["refresh_token"]) |> json_response(400)
    end
  end

  describe "rejected authorization requests" do
    test "an unregistered redirect URI gets an error page, not a redirect", ctx do
      {_verifier, challenge} = Agent.pkce()

      for uri <- ["https://evil.example/cb", ctx.claude.redirect_uri <> "/extra"] do
        conn =
          build_conn()
          |> init_test_session(current_user_id: ctx.owner.id)
          |> get(
            ~p"/oauth/authorize",
            authorize_params(ctx.claude, challenge, %{"redirect_uri" => uri})
          )

        assert html_response(conn, 400) =~ "didn&#39;t register"
      end
    end

    test "another resource, an unknown scope, or no PKCE redirect with an error and iss", ctx do
      {_verifier, challenge} = Agent.pkce()

      cases = [
        {%{"resource" => "https://evil.example/mcp"}, "invalid_target"},
        {%{"scope" => "reviews:read admin"}, "invalid_scope"},
        {%{"code_challenge_method" => "plain"}, "invalid_request"},
        # A public client can't get tokens for an API that needs keys.
        {%{"resource" => nil, "scope" => "keys:write"}, "unauthorized_client"}
      ]

      for {extra, error} <- cases do
        params =
          authorize_params(ctx.claude, challenge, extra) |> Map.reject(&is_nil(elem(&1, 1)))

        conn =
          build_conn()
          |> init_test_session(current_user_id: ctx.owner.id)
          |> get(~p"/oauth/authorize", params)

        assert %{"error" => ^error, "iss" => @issuer, "state" => "st_9"} = redirect_query(conn)
      end
    end

    test "an identity of another account is refused", ctx do
      stranger = user_fixture("stranger")
      {:ok, theirs} = Accounts.create_agent_identity(stranger, %{display_name: "X", handle: "x"})
      {_verifier, challenge} = Agent.pkce()

      conn =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> post(
          ~p"/oauth/authorize",
          authorize_params(ctx.claude, challenge)
          |> Map.merge(%{
            "decision" => "approve",
            "identity_id" => to_string(theirs.id),
            "granted_scopes" => @all_scopes
          })
        )

      assert html_response(conn, 200) =~ "Choose one of your"
      assert Repo.aggregate(IdentityLink, :count) == 0
    end

    test "an identity_id past the database's range gets the consent page, not a 500", ctx do
      {_verifier, challenge} = Agent.pkce()

      conn =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> post(
          ~p"/oauth/authorize",
          authorize_params(ctx.claude, challenge)
          |> Map.merge(%{
            "decision" => "approve",
            "identity_id" => "99999999999999999999",
            "granted_scopes" => @all_scopes
          })
        )

      assert html_response(conn, 200) =~ "Choose one of your agent identities"
      assert Repo.aggregate(AuthorizationCode, :count) == 0
    end

    test "the owner's own human identity is refused, even posted by hand", ctx do
      human = Accounts.human_identity_for(ctx.owner)
      {_verifier, challenge} = Agent.pkce()

      conn =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> post(
          ~p"/oauth/authorize",
          authorize_params(ctx.claude, challenge)
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

    test "an owner with no agents is asked to create one instead of approving", ctx do
      owner = user_fixture("no-agents")
      {_verifier, challenge} = Agent.pkce()

      doc =
        build_conn()
        |> init_test_session(current_user_id: owner.id)
        |> get(~p"/oauth/authorize", authorize_params(ctx.claude, challenge))
        |> html_response(200)
        |> LazyHTML.from_document()

      assert doc |> LazyHTML.query("#poppy-consent-no-agents") |> Enum.any?()
      refute doc |> LazyHTML.query("#poppy-consent-form") |> Enum.any?()
    end

    test "denying sends access_denied back", ctx do
      {_verifier, challenge} = Agent.pkce()

      conn =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> post(
          ~p"/oauth/authorize",
          Map.put(authorize_params(ctx.claude, challenge), "decision", "deny")
        )

      assert %{"error" => "access_denied", "iss" => @issuer} = redirect_query(conn)
    end
  end

  describe "rejected token requests" do
    test "a wrong PKCE verifier", ctx do
      {%{"code" => code}, _verifier} = approve(ctx.claude, ctx.owner, ctx.agent)
      {other_verifier, _} = Agent.pkce()

      assert %{"error" => "invalid_grant"} =
               exchange(ctx.claude, code, other_verifier) |> json_response(400)
    end

    test "a reused code, which also revokes the tokens the first use got", ctx do
      {%{"code" => code}, verifier} = approve(ctx.claude, ctx.owner, ctx.agent)
      tokens = exchange(ctx.claude, code, verifier) |> json_response(200)

      assert %{"error" => "invalid_grant"} =
               exchange(ctx.claude, code, verifier) |> json_response(400)

      assert whoami(tokens["access_token"]).status == 401
    end

    test "a code redeemed by another client, or at another redirect URI", ctx do
      {%{"code" => code}, verifier} = approve(ctx.claude, ctx.owner, ctx.agent)
      other = claude_client()

      assert %{"error" => "invalid_grant"} = exchange(other, code, verifier) |> json_response(400)

      {%{"code" => code}, verifier} = approve(ctx.claude, ctx.owner, ctx.agent)

      assert %{"error" => "invalid_grant"} =
               exchange(ctx.claude, code, verifier, %{
                 "redirect_uri" => ctx.claude.redirect_uri <> "x"
               })
               |> json_response(400)
    end

    test "another resource than the code's", ctx do
      {%{"code" => code}, verifier} = approve(ctx.claude, ctx.owner, ctx.agent)

      assert %{"error" => "invalid_target"} =
               exchange(ctx.claude, code, verifier, %{"resource" => @issuer})
               |> json_response(400)
    end

    test "client authentication the client can't use", ctx do
      {%{"code" => code}, verifier} = approve(ctx.claude, ctx.owner, ctx.agent)

      # Reviews issues no secrets, an unknown client is unknown, and a client
      # whose metadata requires private_key_jwt must send an assertion.
      keyed_client = Agent.new()

      for extra <- [
            %{"client_secret" => "guess"},
            %{"client_id" => "rvc_unknown"},
            %{"client_id" => keyed_client.client_id}
          ] do
        assert %{"error" => "invalid_client"} =
                 exchange(ctx.claude, code, verifier, extra) |> json_response(401)
      end

      # None of those used up the code.
      assert exchange(ctx.claude, code, verifier) |> json_response(200)
    end
  end

  describe "access tokens at /mcp" do
    test "an expired token is refused with a challenge", ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent)
      Repo.update_all(AccessToken, set: [expires_at: ~U[2020-01-01 00:00:00Z]])

      conn = whoami(tokens["access_token"])
      assert conn.status == 401
      assert challenge(conn) =~ ~s(error="invalid_token")
    end

    test "disconnecting in Settings stops the token on its next call", ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent)
      assert whoami(tokens["access_token"]).status == 200

      [link] = OAuth.list_links_for(ctx.owner)
      :ok = OAuth.revoke_link(ctx.owner, link.id)

      assert whoami(tokens["access_token"]).status == 401
      assert refresh(ctx.claude, tokens["refresh_token"]) |> json_response(400)
    end

    test "revoking the refresh token at the revocation endpoint ends the grant", ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent)

      conn =
        build_conn()
        |> post(~p"/oauth/revoke", %{
          "client_id" => ctx.claude.client_id,
          "token" => tokens["refresh_token"]
        })

      assert conn.status == 200
      assert whoami(tokens["access_token"]).status == 401
    end

    test "another API's token is refused at /mcp, and an MCP token at the other API", ctx do
      keyed_client = Agent.new()
      {verifier, challenge} = Agent.pkce()

      conn =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> post(~p"/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => keyed_client.client_id,
          "redirect_uri" => keyed_client.redirect_uri,
          "scope" => "keys:write",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "decision" => "approve",
          "identity_id" => to_string(ctx.agent.id),
          "granted_scopes" => ["keys:write"]
        })

      %{"code" => code} = redirect_query(conn)

      keys_tokens =
        token(
          Map.merge(Agent.client_auth(keyed_client), %{
            "grant_type" => "authorization_code",
            "code" => code,
            "redirect_uri" => keyed_client.redirect_uri,
            "code_verifier" => verifier
          })
        )
        |> json_response(200)

      assert whoami(keys_tokens["access_token"]).status == 401

      mcp_tokens = sign_in(ctx.claude, ctx.owner, ctx.agent)

      assert {:error, :invalid_token} =
               OAuth.authenticate_access_token(mcp_tokens["access_token"], "keys")
    end

    test "blocking the client stops its access tokens at once", ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent)
      assert whoami(tokens["access_token"]).status == 200

      # Only this test's unique client ID is added, so other tests are unaffected.
      previous = Application.get_env(:reviews, OAuth)
      on_exit(fn -> Application.put_env(:reviews, OAuth, previous) end)

      Application.put_env(
        :reviews,
        OAuth,
        Keyword.put(previous, :blocked_clients, [ctx.claude.client_id])
      )

      assert whoami(tokens["access_token"]).status == 401
    end

    test "a resource with a trailing slash is accepted at authorize and at token", ctx do
      keyed_client = Agent.new()
      {verifier, challenge} = Agent.pkce()

      conn =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> post(~p"/oauth/authorize", %{
          "response_type" => "code",
          "client_id" => keyed_client.client_id,
          "redirect_uri" => keyed_client.redirect_uri,
          "scope" => "keys:write",
          "resource" => @issuer <> "/api/keys/",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256",
          "decision" => "approve",
          "identity_id" => to_string(ctx.agent.id),
          "granted_scopes" => ["keys:write"]
        })

      %{"code" => code} = redirect_query(conn)

      assert token(
               Map.merge(Agent.client_auth(keyed_client), %{
                 "grant_type" => "authorization_code",
                 "code" => code,
                 "redirect_uri" => keyed_client.redirect_uri,
                 "code_verifier" => verifier,
                 "resource" => @issuer <> "/api/keys/"
               })
             )
             |> json_response(200)
    end

    test "a GitHub browser session alone is not MCP access", ctx do
      conn =
        %{build_conn() | host: "localhost"}
        |> init_test_session(current_user_id: ctx.owner.id)
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}))

      assert conn.status == 401
    end

    test "Reviews API tokens keep working beside OAuth", ctx do
      {:ok, _token, raw} = Accounts.mint_token(ctx.owner, %{"name" => "cli"})
      result = whoami(raw) |> json_response(200)
      assert result["result"]["structuredContent"]["scopes"] == @all_scopes
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
      {_verifier, challenge} = Agent.pkce()

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
      assert whoami(tokens["access_token"]).status == 200
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

  describe "private_key_jwt clients, as ChatGPT signs in" do
    setup do
      client_id = "https://chatgpt.com/oauth/client.json"
      Clients.forget(client_id)
      rsa = Agent.rsa_key("cimd-test")
      rsa = %{rsa | alg: "RS256", public: Map.put(rsa.public, "alg", "RS256")}

      agent = %Agent{
        client_id: client_id,
        jwks_uri: "https://chatgpt.com/oauth/jwks.json",
        redirect_uri: "https://chatgpt.com/connector_platform_oauth_redirect",
        root: rsa,
        rsa: rsa
      }

      Fetcher.put(client_id, %{
        "client_id" => client_id,
        "client_name" => "ChatGPT",
        "redirect_uris" => [agent.redirect_uri],
        "token_endpoint_auth_method" => "private_key_jwt",
        "token_endpoint_auth_methods_supported" => ["none", "private_key_jwt"],
        "token_endpoint_auth_signing_alg" => "RS256",
        "jwks_uri" => agent.jwks_uri
      })

      Fetcher.put(agent.jwks_uri, %{"keys" => [rsa.public]})
      on_exit(fn -> Clients.forget(client_id) end)
      %{chatgpt: agent}
    end

    test "an RS256 assertion addressed to the token endpoint signs in", ctx do
      {%{"code" => code}, verifier} = approve(ctx.chatgpt, ctx.owner, ctx.agent)

      params =
        Map.merge(Agent.client_auth(ctx.chatgpt, aud: @issuer <> "/oauth/token"), %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => ctx.chatgpt.redirect_uri,
          "code_verifier" => verifier,
          "resource" => @resource
        })

      tokens = token(params) |> json_response(200)
      assert whoami(tokens["access_token"]).status == 200
    end

    test "a bad signature is refused", ctx do
      {%{"code" => code}, verifier} = approve(ctx.chatgpt, ctx.owner, ctx.agent)

      params =
        ctx.chatgpt
        |> Agent.client_auth(aud: @issuer <> "/oauth/token")
        |> Map.update!("client_assertion", &tamper/1)
        |> Map.merge(%{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => ctx.chatgpt.redirect_uri,
          "code_verifier" => verifier
        })

      assert %{"error" => "invalid_client"} = token(params) |> json_response(401)
    end
  end

  test "only clients on the list may address the token endpoint" do
    agent = Agent.new()

    assert {:error, :wrong_audience} =
             Reviews.OAuth.Tokens.verify_client_assertion(
               Agent.client_auth(agent, aud: @issuer <> "/oauth/token")
             )
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
    tokens = sign_in(ctx.claude, ctx.owner, ctx.agent)
    [link] = Repo.all(from l in IdentityLink, where: l.provider == "mcp")
    refute link.refresh_token_hash == tokens["refresh_token"]
    assert link.refresh_token_hash == :crypto.hash(:sha256, tokens["refresh_token"])
  end
end
