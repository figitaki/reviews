defmodule ReviewsWeb.AuthRelayControllerTest do
  use ReviewsWeb.ConnCase

  alias Reviews.AuthRelay
  alias ReviewsWeb.AuthController

  @moduletag :capture_log

  @relay_url "https://reviews.figitaki.dev"
  @preview "reviews-pr-42.fly.dev"
  @secret String.duplicate("s", 64)

  setup do
    original_relay = Application.get_env(:reviews, :auth_relay)
    original_oauth = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)

    # The relay role: the secret plus the app's own GitHub OAuth app. The
    # preview tests below add AUTH_RELAY_URL, which makes the app a client.
    Application.put_env(:reviews, :auth_relay, secret: @secret)

    Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
      client_id: "prod-client-id",
      client_secret: "prod-client-secret"
    )

    on_exit(fn ->
      Application.put_env(:reviews, :auth_relay, original_relay)
      Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, original_oauth)
    end)

    %{state: AuthRelay.new_state()}
  end

  defp on_host(conn, host), do: %{conn | host: host}

  @oauth_state "relay-oauth-state-0123456789"

  # Production's GitHub callback with `session`, as if GitHub returned with
  # `params` and Ueberauth produced `result` ({:ueberauth_auth, auth} or
  # {:ueberauth_failure, failure}).
  defp github_callback(session, params, {key, value}) do
    conn =
      build_conn()
      |> init_test_session(session)
      |> bypass_through(ReviewsWeb.Router, [:browser])
      |> get(~p"/auth/github/callback?#{params}")

    conn |> assign(key, value) |> AuthController.callback(conn.params)
  end

  defp bound_target(state), do: %{host: @preview, state: state, oauth_state: @oauth_state}

  defp github_user_exists?,
    do: Reviews.Repo.get_by(Reviews.Accounts.User, github_id: 77_001) != nil

  defp github_auth do
    %Ueberauth.Auth{
      uid: 77_001,
      info: %Ueberauth.Auth.Info{nickname: "octo", image: nil, email: "octo@example.com"}
    }
  end

  describe "relay" do
    test "asks the user to confirm the preview host", %{conn: conn, state: state} do
      html = conn |> get(~p"/auth/relay?#{[host: @preview, state: state]}") |> html_response(200)
      doc = LazyHTML.from_document(html)

      assert doc |> LazyHTML.query("#auth-relay-confirm h1") |> LazyHTML.text() =~ @preview

      form = LazyHTML.query(doc, ~s|#auth-relay-confirm form[action="/auth/relay"]|)

      assert form |> LazyHTML.query(~s|input[name="host"]|) |> LazyHTML.attribute("value") == [
               @preview
             ]

      assert form |> LazyHTML.query(~s|input[name="state"]|) |> LazyHTML.attribute("value") == [
               state
             ]
    end

    for host <- [
          "evil.example",
          "https://evil.example",
          "//evil.example",
          "reviews.figitaki.dev",
          "reviews-pr-42.fly.dev.evil.example",
          "reviews-pr-42.fly.dev@evil.example",
          "reviews-pr-42.fly.dev:8443",
          "reviews-pr-42.fly.dev/evil",
          "evil.reviews-pr-42.fly.dev",
          "reviews-pr-x.fly.dev",
          ""
        ] do
      test "refuses to send anyone to #{inspect(host)}", %{conn: conn, state: state} do
        params = [host: unquote(host), state: state]

        for conn <- [
              get(conn, ~p"/auth/relay?#{params}"),
              post(build_conn(), ~p"/auth/relay", params)
            ] do
          assert response(conn, 400) =~ "not valid"
          assert get_resp_header(conn, "location") == []
          refute get_session(conn, :auth_relay_target)
        end
      end
    end

    test "refuses a missing or malformed state", %{conn: conn} do
      for params <- [
            [host: @preview],
            [host: @preview, state: "short"],
            [host: @preview, state: "has spaces in it, not a token"]
          ] do
        assert conn |> get(~p"/auth/relay?#{params}") |> response(400)
      end
    end

    test "confirming starts production's GitHub sign-in, bound to its OAuth state", %{
      conn: conn,
      state: state
    } do
      conn = post(conn, ~p"/auth/relay", host: @preview, state: state)

      assert redirected_to(conn) == "/auth/github?relay=1"
      assert get_session(conn, :auth_relay_target) == %{host: @preview, state: state}

      conn = conn |> recycle() |> get(~p"/auth/github?relay=1")

      %URI{host: "github.com", path: "/login/oauth/authorize", query: query} =
        URI.parse(redirected_to(conn))

      query = URI.decode_query(query)
      assert query["client_id"] == "prod-client-id"
      assert query["redirect_uri"] =~ ~r|/auth/github/callback\z|

      assert get_session(conn, :auth_relay_target) ==
               %{host: @preview, state: state, oauth_state: query["state"]}
    end

    # GitHub returns without a code, which Ueberauth reports as a failure
    # after its own state check passed.
    test "the real callback sends a bound sign-in back to the preview", %{
      conn: conn,
      state: state
    } do
      conn = post(conn, ~p"/auth/relay", host: @preview, state: state)
      conn = conn |> recycle() |> get(~p"/auth/github?relay=1")
      oauth_state = URI.decode_query(URI.parse(redirected_to(conn)).query)["state"]

      conn = conn |> recycle() |> get(~p"/auth/github/callback?#{[state: oauth_state]}")

      assert redirected_to(conn) == "https://#{@preview}/auth/relay/accept?error=github"
      refute get_session(conn, :current_user_id)
      refute get_session(conn, :auth_relay_target)
    end

    test "a relay sign-in mints a code and never creates a production session", %{
      state: state
    } do
      conn =
        github_callback(
          %{auth_relay_target: bound_target(state), return_to: "/settings"},
          [state: @oauth_state],
          {:ueberauth_auth, github_auth()}
        )

      %URI{scheme: "https", host: @preview, path: "/auth/relay/accept", query: query} =
        URI.parse(redirected_to(conn))

      assert {:ok, %{github_id: 77_001, username: "octo"}} =
               AuthRelay.redeem_code(URI.decode_query(query)["code"], @preview, state)

      refute get_session(conn, :current_user_id)
      refute get_session(conn, :auth_relay_target)
      refute Phoenix.Flash.get(conn.assigns.flash, :info)
      refute github_user_exists?()
    end

    test "reports a GitHub failure to the preview", %{state: state} do
      failure = %Ueberauth.Failure{
        errors: [%Ueberauth.Failure.Error{message_key: "access_denied"}]
      }

      conn =
        github_callback(
          %{auth_relay_target: bound_target(state)},
          [state: @oauth_state],
          {:ueberauth_failure, failure}
        )

      assert redirected_to(conn) == "https://#{@preview}/auth/relay/accept?error=github"
    end

    test "a state that does not match the relay sign-in is refused", %{state: state} do
      for params <- [[state: "another-oauth-state-0123456"], [state: ""], []],
          target <- [bound_target(state), %{host: @preview, state: state}] do
        conn =
          github_callback(%{auth_relay_target: target}, params, {:ueberauth_auth, github_auth()})

        assert redirected_to(conn) == "/"
        assert Phoenix.Flash.get(conn.assigns.flash, :error) == "GitHub authentication failed."
        refute get_session(conn, :current_user_id)
        refute get_session(conn, :auth_relay_target)
      end

      refute github_user_exists?()
    end

    test "a relay sign-in is refused once the relay is off", %{state: state} do
      Application.put_env(:reviews, :auth_relay, [])

      conn =
        github_callback(
          %{auth_relay_target: bound_target(state)},
          [state: @oauth_state],
          {:ueberauth_auth, github_auth()}
        )

      assert redirected_to(conn) == "/"
      refute get_session(conn, :current_user_id)
      refute github_user_exists?()
    end

    test "a forged state is refused by the real callback", %{conn: conn, state: state} do
      # With a relay sign-in in progress.
      conn = post(conn, ~p"/auth/relay", host: @preview, state: state)
      conn = conn |> recycle() |> get(~p"/auth/github?relay=1")
      conn = conn |> recycle() |> get(~p"/auth/github/callback?#{[state: "forged", code: "x"]}")

      assert redirected_to(conn) == "/"
      refute get_session(conn, :current_user_id)

      # And with a normal sign-in in progress.
      conn = build_conn() |> get(~p"/auth/github")
      conn = conn |> recycle() |> get(~p"/auth/github/callback?#{[state: "forged", code: "x"]}")

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "GitHub authentication failed."
      refute get_session(conn, :current_user_id)
    end

    test "a normal sign-in drops a leftover relay target", %{conn: conn, state: state} do
      conn = post(conn, ~p"/auth/relay", host: @preview, state: state)
      conn = conn |> recycle() |> get(~p"/auth/github?relay=1")
      assert get_session(conn, :auth_relay_target)

      conn = conn |> recycle() |> get(~p"/auth/github?#{[return_to: "/settings"]}")
      assert redirected_to(conn) =~ "https://github.com/login/oauth/authorize"
      refute get_session(conn, :auth_relay_target)

      # relay=1 alone, without the confirm step, is a normal sign-in too.
      conn = build_conn() |> get(~p"/auth/github?relay=1")
      assert redirected_to(conn) =~ "https://github.com/login/oauth/authorize"
      refute get_session(conn, :auth_relay_target)
    end

    test "a normal sign-in still signs in to production" do
      conn =
        github_callback(%{return_to: "/settings"}, [state: "x"], {:ueberauth_auth, github_auth()})

      assert redirected_to(conn) == "/settings"
      assert get_session(conn, :current_user_id)
      assert github_user_exists?()
    end

    test "is off without the secret or GitHub OAuth, and on previews", %{state: state} do
      path = ~p"/auth/relay?#{[host: @preview, state: state]}"

      Application.put_env(:reviews, :auth_relay, [])
      assert build_conn() |> get(path) |> response(404)

      # A preview is a relay client, never a relay.
      Application.put_env(:reviews, :auth_relay, secret: @secret, url: @relay_url)
      assert build_conn() |> get(path) |> response(404)

      Application.put_env(:reviews, :auth_relay, secret: @secret)

      Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
        client_id: nil,
        client_secret: nil
      )

      assert build_conn() |> get(path) |> response(404)
    end
  end

  describe "preview" do
    setup do
      Application.put_env(:reviews, :auth_relay, secret: @secret, url: @relay_url)
    end

    test "sign-in goes to the relay with this host and a fresh state", %{conn: conn} do
      conn =
        conn |> on_host(@preview) |> get(~p"/auth/github?#{[return_to: "/r/abc?patchset=2"]}")

      %URI{query: query} = uri = URI.parse(redirected_to(conn))
      assert "#{uri.scheme}://#{uri.host}#{uri.path}" == @relay_url <> "/auth/relay"

      state = get_session(conn, :auth_relay_state)
      assert URI.decode_query(query) == %{"host" => @preview, "state" => state}
      assert AuthRelay.valid_state?(state)
      assert get_session(conn, :return_to) == "/r/abc?patchset=2"
    end

    defp accept(code, session, host \\ @preview) do
      build_conn()
      |> on_host(host)
      |> init_test_session(session)
      |> get(~p"/auth/relay/accept?#{[code: code]}")
    end

    test "a code signs the user in and returns to the starting page", %{state: state} do
      code = AuthRelay.issue_code(@preview, state, %{github_id: 77_001, username: "octo"})
      conn = accept(code, %{auth_relay_state: state, return_to: "/r/abc?patchset=2"})

      assert redirected_to(conn) == "/r/abc?patchset=2"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Signed in as octo."
      assert get_session(conn, :current_user_id)
      refute get_session(conn, :auth_relay_state)
    end

    test "a code works only once", %{state: state} do
      code = AuthRelay.issue_code(@preview, state, %{github_id: 77_001, username: "octo"})
      assert accept(code, %{auth_relay_state: state}) |> get_session(:current_user_id)

      replay = accept(code, %{auth_relay_state: state, return_to: "/settings"})

      assert redirected_to(replay) == "/settings"
      assert Phoenix.Flash.get(replay.assigns.flash, :error) =~ "sign-in failed"
      refute get_session(replay, :current_user_id)
    end

    test "a code for another preview does not sign in", %{state: state} do
      code =
        AuthRelay.issue_code("reviews-pr-43.fly.dev", state, %{
          github_id: 77_001,
          username: "octo"
        })

      conn = accept(code, %{auth_relay_state: state})

      assert redirected_to(conn) == "/"
      refute get_session(conn, :current_user_id)
    end

    test "an expired code does not sign in", %{state: state} do
      code =
        AuthRelay.issue_code(@preview, state, %{github_id: 77_001, username: "octo"},
          signed_at: System.system_time(:second) - 61
        )

      refute accept(code, %{auth_relay_state: state}) |> get_session(:current_user_id)
    end

    test "a code from another browser's sign-in does not sign in", %{state: state} do
      code = AuthRelay.issue_code(@preview, state, %{github_id: 77_001, username: "octo"})

      refute accept(code, %{}) |> get_session(:current_user_id)

      refute accept(code, %{auth_relay_state: AuthRelay.new_state()})
             |> get_session(:current_user_id)
    end

    test "a GitHub failure from the relay returns to the starting page", %{conn: conn} do
      conn =
        conn
        |> on_host(@preview)
        |> init_test_session(%{return_to: "/settings"})
        |> get(~p"/auth/relay/accept?error=github")

      assert redirected_to(conn) == "/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "sign-in failed"
    end

    test "production never accepts relay codes", %{state: state} do
      code =
        AuthRelay.issue_code("reviews.figitaki.dev", state, %{github_id: 77_001, username: "octo"})

      conn = accept(code, %{auth_relay_state: state}, "reviews.figitaki.dev")

      assert response(conn, 404)
      refute get_session(conn, :current_user_id)
    end
  end
end
