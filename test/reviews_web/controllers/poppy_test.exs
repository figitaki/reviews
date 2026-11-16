defmodule ReviewsWeb.PoppyTest do
  @moduledoc """
  Poppy 1.0 merchant identity, end to end over HTTP: discovery, Direct
  Sign-In, the token and revocation endpoints, and a signed-in comment, with
  the replay, expiry, wrong-audience, cross-tenant, and revocation cases that
  must fail (issue #154).
  """
  use ReviewsWeb.ConnCase, async: true

  import Ecto.Query

  alias Reviews.Accounts
  alias Reviews.Accounts.IdentityLink
  alias Reviews.OAuth
  alias Reviews.OAuth.AccessToken
  alias Reviews.Poppy
  alias Reviews.PoppyTestAgent, as: Agent
  alias Reviews.Repo
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads.Comment

  @issuer "https://reviews.test"

  setup do
    owner = user_fixture("carey")

    {:ok, agent_identity} =
      Accounts.create_agent_identity(owner, %{display_name: "Claude", handle: "claude"})

    {:ok, %{review: review}} =
      ReviewsContext.create_review_with_initial_patchset(owner, %{
        title: "Poppy",
        raw_diff: "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"
      })

    %{owner: owner, identity: agent_identity, review: review, agent: Agent.new()}
  end

  defp user_fixture(name) do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: "#{name}-#{System.unique_integer([:positive])}"
      })

    user
  end

  defp authorize_params(agent, challenge, extra \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => agent.client_id,
        "redirect_uri" => agent.redirect_uri,
        "scope" => "comments:write",
        "state" => "st_123",
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      },
      extra
    )
  end

  # Direct Sign-In: the owner approves, and the agent exchanges the code.
  defp get_code(agent, user, identity, extra \\ %{}) do
    {verifier, challenge} = Agent.pkce()

    conn =
      build_conn()
      |> init_test_session(current_user_id: user.id)
      |> post(
        ~p"/oauth/authorize",
        authorize_params(agent, challenge, extra)
        |> Map.merge(%{
          "decision" => "approve",
          "identity_id" => to_string(identity.id),
          "granted_scopes" => ["comments:write"]
        })
      )

    location = redirected_to(conn, 302)
    query = URI.decode_query(URI.parse(location).query)
    {query, verifier}
  end

  defp exchange(agent, code, verifier, opts \\ []) do
    build_conn()
    |> post(
      ~p"/oauth/token",
      Map.merge(Agent.client_auth(agent, opts), %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => agent.redirect_uri,
        "code_verifier" => verifier
      })
    )
  end

  defp sign_in(agent, user, identity) do
    {%{"code" => code}, verifier} = get_code(agent, user, identity)
    json_response(exchange(agent, code, verifier), 200)
  end

  defp comment_path(review), do: "/api/poppy/v1/reviews/#{review.slug}/comments"

  defp comment_body(extra) do
    Map.merge(
      %{
        "file_path" => "foo",
        "side" => "new",
        "body" => "From a Personal Agent",
        "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
      },
      extra
    )
  end

  defp post_comment(agent, review, opts \\ []) do
    path = comment_path(review)
    headers = Keyword.get_lazy(opts, :headers, fn -> Agent.headers(agent, "POST", path, opts) end)

    Enum.reduce(headers, build_conn(), fn {k, v}, conn -> put_req_header(conn, k, v) end)
    |> post(path, comment_body(Keyword.get(opts, :body, %{})))
  end

  defp comment_count, do: Repo.aggregate(Comment, :count)

  describe "discovery" do
    test "poppy.json, protected resource, and issuer metadata point at one another", %{conn: conn} do
      poppy = conn |> get("/.well-known/poppy.json") |> json_response(200)
      assert poppy["protocol_version"] == "1.0"
      assert poppy["organization"]["domain"] == "reviews.test"
      assert Map.has_key?(poppy["auth"]["scopes"], "comments:write")

      assert poppy["auth"]["scope_hints"]["comments:write"] == %{
               "changes" => "irreversible",
               "personal_data" => false
             }

      assert [%{"type" => "openapi", "url" => @issuer <> "/api/poppy/openapi.json"}] =
               poppy["apis"]

      resource =
        build_conn() |> get("/.well-known/oauth-protected-resource") |> json_response(200)

      assert resource["resource"] == @issuer
      assert resource["authorization_servers"] == [@issuer]

      issuer =
        build_conn() |> get("/.well-known/oauth-authorization-server") |> json_response(200)

      assert issuer["issuer"] == @issuer
      assert @issuer in issuer["protected_resources"]
      assert "refresh_token" in issuer["grant_types_supported"]

      assert Enum.all?(
               ["ES256", "PS384"],
               &(&1 in issuer["token_endpoint_auth_signing_alg_values_supported"])
             )

      openapi = build_conn() |> get("/api/poppy/openapi.json") |> json_response(200)
      assert openapi["servers"] == [%{"url" => @issuer <> "/api/poppy/v1"}]
    end
  end

  describe "Direct Sign-In and a signed-in comment" do
    test "the comment is attributed to the owner-approved Reviews agent", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)
      assert tokens["token_type"] == "Bearer"
      assert tokens["scope"] == "comments:write"
      assert "ppr_" <> _ = tokens["refresh_token"]

      conn =
        post_comment(ctx.agent, ctx.review,
          access_token: tokens["access_token"],
          agent_id: "agt_travel"
        )

      assert %{"comment_id" => comment_id} = json_response(conn, 201)

      comment = Repo.get!(Comment, comment_id)
      assert comment.author_id == ctx.identity.id
      assert comment.identity_link_id

      assert %{
               "provider" => "poppy",
               "client_id" => client_id,
               "client_name_claimed" => "Test Agent",
               "owner_username" => owner_username,
               "identity_handle" => "claude",
               "agent_id_claimed" => "agt_travel",
               "user_id" => sub
             } = comment.attribution

      assert client_id == ctx.agent.client_id
      assert owner_username == ctx.owner.username
      assert sub == ctx.agent.sub

      # The review page gets only the verified facts and labelled claims; the
      # pairwise User ID, Session, and key stay server-side.
      {:ok, snapshot} = Reviews.ReviewView.snapshot(ctx.review, nil)

      [%{comments: [%{attribution: payload}]}] =
        Reviews.ReviewView.thread_payloads_for_file(snapshot, "foo")

      assert payload == %{
               provider: "poppy",
               verified_at: comment.attribution["verified_at"],
               client_id: ctx.agent.client_id,
               client_domain: URI.parse(ctx.agent.client_id).host,
               client_name_claimed: "Test Agent",
               agent_id_claimed: true,
               owner_username: ctx.owner.username,
               approved_at: comment.attribution["approved_at"],
               link_revoked: false
             }

      [link] = OAuth.list_links_for(ctx.owner)
      :ok = OAuth.revoke_link(ctx.owner, link.id)
      {:ok, snapshot} = Reviews.ReviewView.snapshot(ctx.review, nil)

      [%{comments: [%{attribution: payload}]}] =
        Reviews.ReviewView.thread_payloads_for_file(snapshot, "foo")

      assert payload.link_revoked
    end

    test "the redirect carries the issuer and state", ctx do
      {query, _verifier} = get_code(ctx.agent, ctx.owner, ctx.identity)
      assert query["iss"] == @issuer
      assert query["state"] == "st_123"
      assert "ppc_" <> _ = query["code"]
    end

    test "deny returns access_denied with the issuer", ctx do
      {_verifier, challenge} = Agent.pkce()

      conn =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> post(
          ~p"/oauth/authorize",
          Map.put(authorize_params(ctx.agent, challenge), "decision", "deny")
        )

      query = URI.decode_query(URI.parse(redirected_to(conn, 302)).query)
      assert %{"error" => "access_denied", "iss" => @issuer, "state" => "st_123"} = query
    end

    test "the consent page names the verified domain and marks the name as a claim", ctx do
      {_verifier, challenge} = Agent.pkce()

      html =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> get(~p"/oauth/authorize?#{authorize_params(ctx.agent, challenge)}")
        |> html_response(200)

      doc = LazyHTML.from_document(html)
      client = doc |> LazyHTML.query("#poppy-consent-client") |> LazyHTML.text()
      assert client =~ URI.parse(ctx.agent.client_id).host
      assert client =~ "Not verified"
      assert doc |> LazyHTML.query("#poppy-identity-#{ctx.identity.id}") |> Enum.count() == 1
    end

    test "signed out, the authorize page asks for GitHub sign-in and remembers the request",
         ctx do
      {_verifier, challenge} = Agent.pkce()
      conn = get(build_conn(), ~p"/oauth/authorize?#{authorize_params(ctx.agent, challenge)}")

      [href] =
        conn
        |> html_response(200)
        |> LazyHTML.from_document()
        |> LazyHTML.query("#poppy-sign-in-github")
        |> LazyHTML.attribute("href")

      assert "/oauth/authorize?" <> _ = URI.decode_query(URI.parse(href).query)["return_to"]
    end

    test "an unregistered redirect URI gets an error page, not a redirect", ctx do
      {_verifier, challenge} = Agent.pkce()

      params =
        authorize_params(ctx.agent, challenge, %{"redirect_uri" => "https://attacker.example/cb"})

      conn =
        build_conn()
        |> init_test_session(current_user_id: ctx.owner.id)
        |> get(~p"/oauth/authorize?#{params}")

      assert html_response(conn, 400) =~ "poppy-invalid-request"
    end

    test "a loopback redirect URI may use any port", ctx do
      {query, _} =
        get_code(ctx.agent, ctx.owner, ctx.identity, %{
          "redirect_uri" => "http://127.0.0.1:53124/callback"
        })

      assert query["code"]
    end

    test "signed out, the comment endpoint challenges for the scope", ctx do
      conn = post_comment(ctx.agent, ctx.review)

      assert json_response(conn, 401)
      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer scope="comments:write")]
      assert comment_count() == 0
    end

    test "signed out, a review can be read with a verified Session header", ctx do
      path = "/api/poppy/v1/reviews/#{ctx.review.slug}"

      conn =
        Enum.reduce(Agent.headers(ctx.agent, "GET", path), build_conn(), fn {k, v}, c ->
          put_req_header(c, k, v)
        end)
        |> get(path)

      assert json_response(conn, 200)["slug"] == ctx.review.slug
    end

    test "a missing Session header or Poppy-Version is refused", ctx do
      path = "/api/poppy/v1/reviews/#{ctx.review.slug}"

      assert %{"error" => "invalid_session"} =
               build_conn()
               |> put_req_header("poppy-version", "1.0")
               |> get(path)
               |> json_response(400)

      [{"poppy-session", jwt} | _] = Agent.headers(ctx.agent, "GET", path)

      assert %{"error" => "version_unsupported"} =
               build_conn()
               |> put_req_header("poppy-session", jwt)
               |> get(path)
               |> json_response(400)
    end

    test "refresh issues a new access token for the same link", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)

      refreshed =
        build_conn()
        |> post(
          ~p"/oauth/token",
          Map.merge(Agent.client_auth(ctx.agent), %{
            "grant_type" => "refresh_token",
            "refresh_token" => tokens["refresh_token"]
          })
        )
        |> json_response(200)

      assert refreshed["access_token"] != tokens["access_token"]

      assert json_response(
               post_comment(ctx.agent, ctx.review, access_token: refreshed["access_token"]),
               201
             )
    end
  end

  describe "replay" do
    test "the same Session JWT twice publishes once", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)

      headers =
        Agent.headers(ctx.agent, "POST", comment_path(ctx.review),
          access_token: tokens["access_token"]
        )

      assert json_response(post_comment(ctx.agent, ctx.review, headers: headers), 201)

      assert %{"error" => "invalid_session"} =
               json_response(post_comment(ctx.agent, ctx.review, headers: headers), 400)

      assert comment_count() == 1
    end

    test "a code works once, and its reuse revokes what it issued", ctx do
      {%{"code" => code}, verifier} = get_code(ctx.agent, ctx.owner, ctx.identity)
      tokens = json_response(exchange(ctx.agent, code, verifier), 200)

      assert %{"error" => "invalid_grant"} =
               json_response(exchange(ctx.agent, code, verifier), 400)

      conn = post_comment(ctx.agent, ctx.review, access_token: tokens["access_token"])
      assert %{"error" => "invalid_token"} = json_response(conn, 401)
    end

    test "a client assertion works once", ctx do
      params =
        Map.merge(Agent.client_auth(ctx.agent), %{
          "grant_type" => "refresh_token",
          "refresh_token" => "nope"
        })

      assert %{"error" => "invalid_grant"} =
               build_conn() |> post(~p"/oauth/token", params) |> json_response(400)

      assert %{"error" => "invalid_client"} =
               build_conn() |> post(~p"/oauth/token", params) |> json_response(401)
    end
  end

  describe "expiry" do
    test "an old Session JWT is refused", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)

      conn =
        post_comment(ctx.agent, ctx.review,
          access_token: tokens["access_token"],
          iat: Agent.now() - 300
        )

      assert %{"error" => "invalid_session"} = json_response(conn, 400)
    end

    test "an expired delegation is refused", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)
      now = Agent.now()
      delegation = Agent.delegation(ctx.agent, iat: now - 7200, exp: now - 60)

      conn =
        post_comment(ctx.agent, ctx.review,
          access_token: tokens["access_token"],
          delegation: delegation
        )

      assert %{"error" => "invalid_session"} = json_response(conn, 400)
    end

    test "an expired access token is invalid_token", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)
      Repo.update_all(AccessToken, set: [expires_at: DateTime.add(DateTime.utc_now(), -1)])

      conn = post_comment(ctx.agent, ctx.review, access_token: tokens["access_token"])
      assert %{"error" => "invalid_token"} = json_response(conn, 401)
      assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
    end

    test "an expired code is invalid_grant", ctx do
      {%{"code" => code}, verifier} = get_code(ctx.agent, ctx.owner, ctx.identity)

      Repo.update_all(OAuth.AuthorizationCode,
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
      )

      assert %{"error" => "invalid_grant"} =
               json_response(exchange(ctx.agent, code, verifier), 400)
    end

    test "an expired client assertion is invalid_client", ctx do
      {%{"code" => code}, verifier} = get_code(ctx.agent, ctx.owner, ctx.identity)
      now = Agent.now()

      conn = exchange(ctx.agent, code, verifier, iat: now - 600, exp: now - 300)
      assert %{"error" => "invalid_client"} = json_response(conn, 401)
    end
  end

  describe "wrong audience" do
    test "a Session JWT for another Company is refused", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)

      for aud <- ["https://other.example", @issuer <> "/"] do
        conn = post_comment(ctx.agent, ctx.review, access_token: tokens["access_token"], aud: aud)
        assert %{"error" => "invalid_session"} = json_response(conn, 400)
      end

      assert comment_count() == 0
    end

    test "a Session JWT signed for another URL or method is refused", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)

      for opts <- [[htu: @issuer <> "/api/poppy/v1/reviews/other/comments"], [htm: "GET"]] do
        conn = post_comment(ctx.agent, ctx.review, [access_token: tokens["access_token"]] ++ opts)
        assert %{"error" => "invalid_session"} = json_response(conn, 400)
      end
    end

    test "a client assertion addressed to the token endpoint is refused", ctx do
      {%{"code" => code}, verifier} = get_code(ctx.agent, ctx.owner, ctx.identity)

      conn = exchange(ctx.agent, code, verifier, aud: @issuer <> "/oauth/token")
      assert %{"error" => "invalid_client"} = json_response(conn, 401)
    end
  end

  describe "cross-tenant" do
    test "an access token only works with Session JWTs from the client it was issued to", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)
      other = Agent.new()

      conn = post_comment(other, ctx.review, access_token: tokens["access_token"])
      assert %{"error" => "invalid_session"} = json_response(conn, 400)
      assert comment_count() == 0
    end

    test "an owner can't link an identity they don't own", ctx do
      stranger = user_fixture("mallory")
      {_verifier, challenge} = Agent.pkce()

      conn =
        build_conn()
        |> init_test_session(current_user_id: stranger.id)
        |> post(
          ~p"/oauth/authorize",
          authorize_params(ctx.agent, challenge)
          |> Map.merge(%{
            "decision" => "approve",
            "identity_id" => to_string(ctx.identity.id),
            "granted_scopes" => ["comments:write"]
          })
        )

      assert html_response(conn, 200) =~ "Choose one of your agent identities"
      assert Repo.aggregate(OAuth.AuthorizationCode, :count) == 0
    end

    test "another client can't redeem a code or use a refresh token", ctx do
      other = Agent.new()
      {%{"code" => code}, verifier} = get_code(ctx.agent, ctx.owner, ctx.identity)

      assert %{"error" => "invalid_grant"} = json_response(exchange(other, code, verifier), 400)

      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)

      conn =
        post(
          build_conn(),
          ~p"/oauth/token",
          Map.merge(Agent.client_auth(other), %{
            "grant_type" => "refresh_token",
            "refresh_token" => tokens["refresh_token"]
          })
        )

      assert %{"error" => "invalid_grant"} = json_response(conn, 400)
    end

    test "a Session that acted as one identity can't switch to another", ctx do
      {:ok, second} =
        Accounts.create_agent_identity(ctx.owner, %{display_name: "Codex", handle: "codex"})

      first_tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)
      second_tokens = sign_in(ctx.agent, ctx.owner, second)

      assert json_response(
               post_comment(ctx.agent, ctx.review,
                 access_token: first_tokens["access_token"],
                 sid: "shared_sid"
               ),
               201
             )

      conn =
        post_comment(ctx.agent, ctx.review,
          access_token: second_tokens["access_token"],
          sid: "shared_sid"
        )

      assert %{"error" => "session_ended"} = json_response(conn, 400)

      # A new Session can use the second identity.
      assert json_response(
               post_comment(ctx.agent, ctx.review,
                 access_token: second_tokens["access_token"],
                 sid: "new_sid"
               ),
               201
             )
    end

    test "Poppy tokens and CLI tokens don't cross over", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> tokens["access_token"])
        |> get(~p"/api/v1/me")

      assert json_response(conn, 401)

      {:ok, _token, raw} =
        Accounts.mint_token(ctx.owner, %{"name" => "cli", "identity_id" => ctx.identity.id})

      conn = post_comment(ctx.agent, ctx.review, access_token: raw)
      assert %{"error" => "invalid_token"} = json_response(conn, 401)

      # The CLI path itself still works.
      conn =
        build_conn() |> put_req_header("authorization", "Bearer " <> raw) |> get(~p"/api/v1/me")

      assert json_response(conn, 200)["identity"]["handle"] == "claude"
    end
  end

  describe "revocation" do
    test "the owner revoking the link stops the access and refresh tokens at once", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)
      assert [link] = OAuth.list_links_for(ctx.owner)

      assert {:error, :not_found} = OAuth.revoke_link(user_fixture("other"), link.id)
      assert :ok = OAuth.revoke_link(ctx.owner, link.id)

      assert %{"error" => "invalid_token"} =
               json_response(
                 post_comment(ctx.agent, ctx.review, access_token: tokens["access_token"]),
                 401
               )

      conn =
        post(
          build_conn(),
          ~p"/oauth/token",
          Map.merge(Agent.client_auth(ctx.agent), %{
            "grant_type" => "refresh_token",
            "refresh_token" => tokens["refresh_token"]
          })
        )

      assert %{"error" => "invalid_grant"} = json_response(conn, 400)
    end

    test "the agent revoking its refresh token signs out", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)

      conn =
        post(
          build_conn(),
          ~p"/oauth/revoke",
          Map.merge(Agent.client_auth(ctx.agent), %{
            "token" => tokens["refresh_token"],
            "token_type_hint" => "refresh_token"
          })
        )

      assert response(conn, 200) == ""
      assert Repo.one!(from l in IdentityLink, select: l.revoked_at)

      assert %{"error" => "invalid_token"} =
               json_response(
                 post_comment(ctx.agent, ctx.review, access_token: tokens["access_token"]),
                 401
               )
    end

    test "another client can't revoke someone else's refresh token", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)
      other = Agent.new()

      conn =
        post(
          build_conn(),
          ~p"/oauth/revoke",
          Map.merge(Agent.client_auth(other), %{"token" => tokens["refresh_token"]})
        )

      assert response(conn, 200) == ""

      assert json_response(
               post_comment(ctx.agent, ctx.review, access_token: tokens["access_token"]),
               201
             )
    end

    test "a Personal Agent key removed from its key set can't sign in or act", ctx do
      tokens = sign_in(ctx.agent, ctx.owner, ctx.identity)
      Agent.publish(ctx.agent, %{}, [])
      Reviews.OAuth.Clients.forget(ctx.agent.client_id)

      assert %{"error" => "invalid_session"} =
               json_response(
                 post_comment(ctx.agent, ctx.review, access_token: tokens["access_token"]),
                 400
               )
    end
  end

  describe "forged names" do
    test "names in the client metadata, JWT, or body don't change who the author is", ctx do
      agent = Agent.new(metadata: %{"client_name" => ctx.owner.username <> " (verified)"})
      tokens = sign_in(agent, ctx.owner, ctx.identity)
      human = Accounts.human_identity_for(ctx.owner)

      conn =
        post_comment(agent, ctx.review,
          access_token: tokens["access_token"],
          body: %{
            "author_id" => human.id,
            "identity_id" => human.id,
            "author" => ctx.owner.username
          }
        )

      comment = Repo.get!(Comment, json_response(conn, 201)["comment_id"])
      assert comment.author_id == ctx.identity.id
      assert comment.attribution["client_name_claimed"] == ctx.owner.username <> " (verified)"
    end
  end
end
