defmodule ReviewsWeb.MCPOAuthTest do
  @moduledoc """
  OAuth for `/mcp` over HTTP (issue #109), on the gatekeep issuer: discovery
  from a 401, sign-in with a client metadata document (Claude) and with
  `private_key_jwt` (ChatGPT), then tool calls as the chosen agent, limited to
  the granted scopes. The issuer itself is tested in `ReviewsWeb.OAuthTest`;
  these tests cover what `/mcp` adds. Most are cases that must fail.
  """
  use ReviewsWeb.ConnCase, async: true

  alias Reviews.Accounts
  alias Reviews.OAuth
  alias Reviews.OAuthTestClient, as: Client
  alias Reviews.OAuthTestClient.Fetcher
  alias Reviews.Repo
  alias Reviews.Reviews, as: ReviewsContext

  @issuer "https://reviews.test"
  @resource "https://reviews.test/mcp"
  @metadata_url "https://reviews.test/.well-known/oauth-protected-resource/mcp"
  @all_scopes ["reviews:read", "reviews:write", "comments:write", "threads:write"]
  @test_resource "https://reviews.test/api/test"
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

  defp comment_on(token, review, body \\ "Please rename this") do
    call_tool(token, "reviews_post_comment", %{
      "review" => review.slug,
      "body" => body,
      "path" => "foo",
      "line" => 1
    })
  end

  describe "discovery" do
    test "a 401 from /mcp names the protected resource metadata and the scopes" do
      conn = mcp(nil, "tools/list")
      assert conn.status == 401
      value = challenge(conn)
      assert value =~ ~r/^Bearer resource_metadata="#{Regex.escape(@metadata_url)}"/
      assert value =~ ~s(scope="#{Enum.join(@all_scopes, " ")}")
      refute value =~ "error="

      conn = mcp("gka_not-a-token", "tools/list")
      assert conn.status == 401
      assert challenge(conn) =~ ~s(resource_metadata="#{@metadata_url}")
      assert challenge(conn) =~ ~s(error="invalid_token")
    end

    @tag :capture_log
    test "Claude's and ChatGPT's origins get the 401 challenge; other sites a 403" do
      probe = fn origin, method ->
        %{build_conn() | host: "localhost"}
        |> put_req_header("origin", origin)
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("content-type", "application/json")
        |> dispatch(
          ReviewsWeb.Endpoint,
          method,
          "/mcp",
          ~s({"jsonrpc":"2.0","id":0,"method":"initialize","params":{}})
        )
      end

      for origin <- ["https://claude.ai", "https://claude.com", "https://chatgpt.com"],
          method <- [:post, :get] do
        conn = probe.(origin, method)
        assert conn.status == 401, "#{method} from #{origin}"
        assert challenge(conn) =~ ~s(resource_metadata="#{@metadata_url}")
        assert get_resp_header(conn, "access-control-allow-origin") == [origin]
        assert hd(get_resp_header(conn, "access-control-expose-headers")) =~ "www-authenticate"
      end

      preflight =
        %{build_conn() | host: "localhost"}
        |> put_req_header("origin", "https://claude.ai")
        |> put_req_header("access-control-request-method", "POST")
        |> options("/mcp")

      assert preflight.status == 204
      assert hd(get_resp_header(preflight, "access-control-allow-headers")) =~ "authorization"

      assert probe.("https://evil.example", :post).status == 403
    end

    test "protected resource and issuer metadata lead to the sign-in endpoints", %{conn: conn} do
      resource =
        conn |> get("/.well-known/oauth-protected-resource/mcp") |> json_response(200)

      assert resource["resource"] == @resource
      assert resource["authorization_servers"] == [@issuer]
      assert resource["scopes_supported"] == @all_scopes

      issuer =
        build_conn() |> get("/.well-known/oauth-authorization-server") |> json_response(200)

      assert issuer["issuer"] == @issuer
      assert issuer["code_challenge_methods_supported"] == ["S256"]
      # Claude picks client metadata documents only when `none` is listed too.
      assert "none" in issuer["token_endpoint_auth_methods_supported"]
      assert "private_key_jwt" in issuer["token_endpoint_auth_methods_supported"]
      assert issuer["client_id_metadata_document_supported"] == true
      assert issuer["authorization_response_iss_parameter_supported"] == true
      assert issuer["registration_endpoint"] == @issuer <> "/oauth/register"
      assert Enum.all?(@all_scopes, &(&1 in issuer["scopes_supported"]))
      assert @resource in issuer["protected_resources"]
    end
  end

  describe "sign-in with a client metadata document" do
    test "the consent page shows the connector text and offers only the owner's agents", ctx do
      {_verifier, challenge} = Client.pkce()

      doc =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> get(~p"/oauth/authorize", authorize_params(ctx.claude, challenge))
        |> html_response(200)
        |> LazyHTML.from_document()

      assert LazyHTML.text(doc) =~ "never as you"
      human = Accounts.human_identity_for(ctx.owner)
      refute doc |> LazyHTML.query("input[value='#{human.id}'][name=identity_id]") |> Enum.any?()

      assert doc
             |> LazyHTML.query("input[value='#{ctx.agent.id}'][name=identity_id]")
             |> Enum.any?()
    end

    test "Claude's real document is recognized; a lookalike that calls itself Claude is not",
         ctx do
      client_id = "https://claude.ai/oauth/mcp-oauth-client-metadata"
      redirect_uri = "https://claude.ai/api/mcp/auth_callback"

      # As https://claude.ai/oauth/mcp-oauth-client-metadata served it on 2026-11-19.
      Fetcher.put(client_id, %{
        "client_id" => client_id,
        "client_name" => "Claude",
        "client_uri" => "https://claude.ai",
        "redirect_uris" => [redirect_uri],
        "grant_types" => [
          "authorization_code",
          "refresh_token",
          "urn:ietf:params:oauth:grant-type:jwt-bearer"
        ],
        "response_types" => ["code"],
        "token_endpoint_auth_method" => "none"
      })

      consent = fn client ->
        {_verifier, challenge} = Client.pkce()

        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> get(~p"/oauth/authorize", authorize_params(client, challenge))
        |> html_response(200)
        |> LazyHTML.from_document()
      end

      doc = consent.(%{client_id: client_id, redirect_uri: redirect_uri})

      # The page names the account, in place of the sign-in toast over the form.
      assert doc |> LazyHTML.query("#poppy-consent-account") |> LazyHTML.text() =~
               ctx.owner.username

      known = doc |> LazyHTML.query("#poppy-consent-known") |> LazyHTML.text()
      assert known =~ "Claude"
      assert known =~ "Recognized app"
      assert known =~ "Anthropic"
      refute doc |> LazyHTML.query("#poppy-consent-client") |> LazyHTML.text() =~ "Not verified"

      assert doc |> LazyHTML.query("#poppy-consent-known img") |> LazyHTML.attribute("src") ==
               ["/images/connectors/claude.png"]

      # Reads are always part of the grant; each write can be left out.
      assert doc
             |> LazyHTML.query("#poppy-consent-scopes input[type=hidden]")
             |> LazyHTML.attribute("value") == ["reviews:read"]

      assert doc
             |> LazyHTML.query("#poppy-consent-scopes input[type=checkbox]")
             |> LazyHTML.attribute("value") == [
               "reviews:write",
               "comments:write",
               "threads:write"
             ]

      # Claude returns you to claude.ai, which the card already names, so the
      # callback and client ID wait behind Details.
      assert doc |> LazyHTML.query("#poppy-consent-returns-to") |> Enum.count() == 1

      assert doc
             |> LazyHTML.query("#poppy-consent-details #poppy-consent-returns-to")
             |> Enum.any?()

      assert doc |> LazyHTML.query("#poppy-consent-details") |> LazyHTML.text() =~ client_id

      lookalike = consent.(ctx.claude)
      refute lookalike |> LazyHTML.query("#poppy-consent-known") |> Enum.any?()

      refute lookalike
             |> LazyHTML.query("#poppy-consent-details #poppy-consent-returns-to")
             |> Enum.any?()

      assert lookalike |> LazyHTML.query("#poppy-consent-returns-to") |> Enum.count() == 1

      assert lookalike |> LazyHTML.query("#poppy-consent-client") |> LazyHTML.text() =~
               "Not verified"
    end

    test "the connector acts as the agent the owner chose, with the scopes granted", ctx do
      {query, verifier} = approve(ctx.claude, ctx.owner, ctx.agent)
      assert %{"code" => code, "state" => "st_9", "iss" => @issuer} = query

      body = exchange(ctx.claude, code, verifier) |> json_response(200)
      assert %{"token_type" => "Bearer", "refresh_token" => _} = body

      result = whoami(body["access_token"]) |> json_response(200)

      assert %{"identity" => %{"handle" => "claude", "kind" => "agent"}} =
               result["result"]["structuredContent"]

      assert result["result"]["structuredContent"]["scopes"] == @all_scopes

      [grant] = OAuth.list_grants_for(ctx.owner)
      assert grant.resource == @resource
      assert grant.client_id == ctx.claude.client_id
    end

    test "refresh tokens rotate", ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent)
      fresh = refresh(ctx.claude, tokens["refresh_token"]) |> json_response(200)
      refute fresh["refresh_token"] == tokens["refresh_token"]

      assert %{"error" => "invalid_grant"} =
               refresh(ctx.claude, tokens["refresh_token"]) |> json_response(400)
    end

    test "an identity_id past the database's range gets the consent page, not a 500", ctx do
      {_verifier, challenge} = Client.pkce()

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

      assert conn.status == 200
      assert Repo.aggregate("gatekeep_codes", :count) == 0
    end
  end

  describe "scopes at /mcp" do
    test "a read-only grant hides and refuses the write tools", ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent, ["reviews:read"])

      tools = mcp(tokens["access_token"], "tools/list") |> json_response(200)
      names = Enum.map(tools["result"]["tools"], & &1["name"])
      assert "reviews_get_review" in names
      refute "reviews_post_comment" in names

      conn = comment_on(tokens["access_token"], ctx.review)
      assert conn.status == 403
      assert challenge(conn) =~ ~s(error="insufficient_scope")
      assert challenge(conn) =~ ~s(resource_metadata="#{@metadata_url}")
      assert challenge(conn) =~ ~s(scope="comments:write")
    end

    test "comments:write lets a connector comment, recorded with its app, but not resolve", ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent, ["reviews:read", "comments:write"])

      result = comment_on(tokens["access_token"], ctx.review) |> json_response(200)
      refute result["result"]["isError"]

      [comment] = Repo.all(Reviews.Threads.Comment)
      assert comment.author_id == ctx.agent.id
      assert comment.attribution["provider"] == "mcp"
      assert comment.attribution["client_id"] == ctx.claude.client_id
      [grant] = OAuth.list_grants_for(ctx.owner)
      assert comment.oauth_grant_id == grant.id

      conn =
        call_tool(tokens["access_token"], "reviews_update_thread_status", %{
          "review" => ctx.review.slug,
          "thread_id" => comment.thread_id,
          "status" => "resolved"
        })

      assert conn.status == 403
      assert challenge(conn) =~ ~s(scope="threads:write")
    end

    test "Policy refuses a delegated write its scopes don't name, even past the transport", ctx do
      identity = ctx.agent
      principal = Reviews.Principal.delegated(identity, ctx.owner, ["comments:write"], nil, :mcp)
      refute Reviews.Policy.can?(principal, :push, ctx.review)

      thread = %{author: identity}
      refute Reviews.Policy.can?(principal, {:update_thread_status, thread}, ctx.review)

      full = Reviews.Principal.delegated(identity, ctx.owner, @all_scopes, nil, :mcp)
      assert Reviews.Policy.can?(full, :push, ctx.review)
    end
  end

  describe "access tokens at /mcp" do
    test "fetch reads any review by link; search stays within the account", ctx do
      stranger = user_fixture("stranger")

      {:ok, %{review: foreign}} =
        ReviewsContext.create_review_with_initial_patchset(stranger, %{
          title: "Not yours",
          raw_diff: @diff
        })

      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent, ["reviews:read"])

      fetched =
        call_tool(tokens["access_token"], "fetch", %{"id" => foreign.slug}) |> json_response(200)

      assert fetched["result"]["structuredContent"]["title"] == "Not yours"

      search =
        call_tool(tokens["access_token"], "search", %{"query" => ""}) |> json_response(200)

      ids = Enum.map(search["result"]["structuredContent"]["results"], & &1["id"])
      assert ctx.review.slug in ids
      refute foreign.slug in ids
    end

    test "disconnecting in Settings stops the token on its next call", ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent)
      assert whoami(tokens["access_token"]).status == 200

      [grant] = OAuth.list_grants_for(ctx.owner)
      :ok = OAuth.revoke_grant(ctx.owner, grant.id)

      conn = whoami(tokens["access_token"])
      assert conn.status == 401
      assert challenge(conn) =~ ~s(resource_metadata="#{@metadata_url}")
    end

    test "another API's token is refused at /mcp, and an MCP token at the other API", ctx do
      {%{"code" => code}, verifier} =
        approve(ctx.claude, ctx.owner, ctx.agent, %{"resource" => @test_resource}, [
          "test:read"
        ])

      other =
        exchange(ctx.claude, code, verifier, %{"resource" => @test_resource})
        |> json_response(200)

      assert whoami(other["access_token"]).status == 401

      mcp_tokens = sign_in(ctx.claude, ctx.owner, ctx.agent)

      assert {:error, _} =
               OAuth.authenticate_access_token(@test_resource, %{
                 authorization: "Bearer " <> mcp_tokens["access_token"],
                 dpop: [],
                 method: "GET",
                 path: "/api/test"
               })
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

    test "Reviews API tokens keep working beside OAuth, with every scope", ctx do
      {:ok, _token, raw} = Accounts.mint_token(ctx.owner, %{"name" => "cli"})
      result = whoami(raw) |> json_response(200)
      assert result["result"]["structuredContent"]["scopes"] == @all_scopes
    end
  end

  describe "reviews_list" do
    setup ctx do
      agent_review = Reviews.ReviewIndexFixtures.review!(ctx.agent, "Agent review")
      stranger = user_fixture("stranger")
      foreign = Reviews.ReviewIndexFixtures.review!(stranger, "Not yours")
      %{agent_review: agent_review, foreign: foreign}
    end

    defp listed(token, args \\ %{}) do
      call_tool(token, "reviews_list", args)
      |> json_response(200)
      |> get_in(["result", "structuredContent"])
    end

    defp slugs(page), do: Enum.map(page["reviews"], & &1["slug"])

    test "an OAuth connector lists the whole account; an agent API token only its agent's", ctx do
      oauth = sign_in(ctx.claude, ctx.owner, ctx.agent, ["reviews:read"])
      page = listed(oauth["access_token"])
      assert page["scope"] == "account"
      assert Enum.sort(slugs(page)) == Enum.sort([ctx.review.slug, ctx.agent_review.slug])
      refute ctx.foreign.slug in slugs(page)

      {:ok, _, agent_raw} =
        Accounts.mint_token(ctx.owner, %{"name" => "agent", "identity_id" => ctx.agent.id})

      page = listed(agent_raw)
      assert page["scope"] == "identity"
      assert slugs(page) == [ctx.agent_review.slug]

      {:ok, _, human_raw} = Accounts.mint_token(ctx.owner, %{"name" => "cli"})
      assert listed(human_raw)["scope"] == "account"
    end

    test "takes #83's filters and pages with cursors bound to them", ctx do
      token = sign_in(ctx.claude, ctx.owner, ctx.agent, ["reviews:read"])["access_token"]

      assert slugs(listed(token, %{"q" => "agent"})) == [ctx.agent_review.slug]
      assert slugs(listed(token, %{"author" => "claude"})) == [ctx.agent_review.slug]

      first = listed(token, %{"limit" => 1})
      assert [one] = slugs(first)
      assert first["next_cursor"] =~ ~r/^c\d+\.0\.\d+$/

      second = listed(token, %{"limit" => 1, "cursor" => first["next_cursor"]})
      assert [two] = slugs(second)
      assert Enum.sort([one, two]) == Enum.sort([ctx.review.slug, ctx.agent_review.slug])
      assert second["next_cursor"] == nil

      # A cursor continues only the list it came from.
      result =
        call_tool(token, "reviews_list", %{"q" => "agent", "cursor" => first["next_cursor"]})
        |> json_response(200)

      assert result["result"]["isError"] == true

      bad = call_tool(token, "reviews_list", %{"role" => "nobody"}) |> json_response(200)
      # The input schema's enum refuses it before the handler runs.
      assert bad["error"] || bad["result"]["isError"]
    end
  end

  describe "Reviews.Policy.list_viewer/1" do
    test "a connector grant at /mcp lists the account; other agent principals one identity",
         ctx do
      alias Reviews.{Policy, Principal}
      human = Accounts.human_identity_for(ctx.owner)

      assert Policy.list_viewer(Principal.delegated(ctx.agent, ctx.owner, [], nil, :mcp)) ==
               ctx.owner

      assert Policy.list_viewer(Principal.new(human, :api_token, ctx.owner)) == ctx.owner
      assert Policy.list_viewer(Principal.new(ctx.agent, :api_token, ctx.owner)) == ctx.agent
      # An agent API token at /mcp is not a connector grant.
      assert Policy.list_viewer(Principal.new(ctx.agent, :mcp, ctx.owner)) == ctx.agent
      # Poppy agents act for themselves.
      assert Policy.list_viewer(Principal.delegated(ctx.agent, ctx.owner, [], nil, :poppy)) ==
               ctx.agent
    end
  end

  describe "private_key_jwt clients, as ChatGPT signs in" do
    # ChatGPT's client ID, with an RS256 key; the fetcher serves it in tests.
    defp keyed_client(base) do
      rsa = Client.rsa_key("rsa-#{System.unique_integer([:positive])}", "RS256")
      client = %{Client.new(base: base) | rsa: rsa}

      Client.publish(
        client,
        %{"token_endpoint_auth_methods_supported" => ["none", "private_key_jwt"]},
        [rsa.public]
      )
    end

    defp keyed_exchange(client, code, verifier, aud) do
      Client.client_auth(client, rsa: true, aud: aud)
      |> Map.merge(%{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => client.redirect_uri,
        "code_verifier" => verifier,
        "resource" => @resource
      })
      |> token()
    end

    test "ChatGPT's assertion addressed to the token endpoint signs in", ctx do
      chatgpt = keyed_client("https://chatgpt.com/oauth")
      assert chatgpt.client_id == "https://chatgpt.com/oauth/client.json"

      {%{"code" => code}, verifier} = approve(chatgpt, ctx.owner, ctx.agent)
      tokens = keyed_exchange(chatgpt, code, verifier, @issuer <> "/oauth/token")
      assert whoami(json_response(tokens, 200)["access_token"]).status == 200
    end

    test "another client may not address the token endpoint", ctx do
      other = keyed_client("https://other#{System.unique_integer([:positive])}.example")
      {%{"code" => code}, verifier} = approve(other, ctx.owner, ctx.agent)

      assert %{"error" => "invalid_client"} =
               keyed_exchange(other, code, verifier, @issuer <> "/oauth/token")
               |> json_response(401)
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

    test "every tool has a title and accurate hints, so clients can sort reads from writes",
         ctx do
      tokens = sign_in(ctx.claude, ctx.owner, ctx.agent)
      tools = mcp(tokens["access_token"], "tools/list") |> json_response(200)

      for tool <- tools["result"]["tools"] do
        assert is_binary(tool["title"]) and tool["title"] != "", tool["name"]
        assert [%{"type" => "oauth2"}] = tool["_meta"]["securitySchemes"]
      end

      hints =
        Map.new(tools["result"]["tools"], fn tool ->
          {tool["name"],
           Map.take(
             tool["annotations"],
             ~w(readOnlyHint destructiveHint idempotentHint openWorldHint)
           )}
        end)

      writes = %{
        "reviews_create_review" => false,
        "reviews_append_revision" => false,
        "reviews_post_comment" => false,
        "reviews_update_thread_status" => true
      }

      for {name, hint} <- hints do
        assert hint["destructiveHint"] == false, name
        assert hint["openWorldHint"] == false, name

        case Map.fetch(writes, name) do
          {:ok, idempotent?} ->
            assert hint["readOnlyHint"] == false, name
            assert hint["idempotentHint"] == idempotent?, name

          :error ->
            assert hint["readOnlyHint"] == true, name
            assert hint["idempotentHint"] == true, name
        end
      end

      assert Enum.all?(Map.keys(writes), &Map.has_key?(hints, &1))
      assert Enum.all?(~w(reviews_whoami reviews_list search fetch), &Map.has_key?(hints, &1))
    end
  end
end
