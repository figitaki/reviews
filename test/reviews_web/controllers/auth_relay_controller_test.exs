defmodule ReviewsWeb.AuthRelayControllerTest do
  use ReviewsWeb.ConnCase

  alias Reviews.AuthRelay
  alias ReviewsWeb.AuthRelayController

  @moduletag :capture_log

  @relay_url "https://reviews.figitaki.dev"
  @preview "reviews-pr-42.fly.dev"

  setup do
    original_relay = Application.get_env(:reviews, :auth_relay)
    original_oauth = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)

    # One app plays both roles here; real apps differ by host and config.
    Application.put_env(:reviews, :auth_relay,
      secret: String.duplicate("s", 64),
      url: @relay_url,
      github_client_id: "relay-client-id",
      github_client_secret: "relay-client-secret"
    )

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

  defp relay_callback(session, auth_assign) do
    build_conn()
    |> init_test_session(session)
    |> bypass_through(ReviewsWeb.Router, [:browser])
    |> get(~p"/auth/relay/github/callback")
    |> assign(elem(auth_assign, 0), elem(auth_assign, 1))
    |> AuthRelayController.callback(%{})
  end

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

    test "confirming starts GitHub sign-in with the preview OAuth app", %{
      conn: conn,
      state: state
    } do
      conn = post(conn, ~p"/auth/relay", host: @preview, state: state)

      assert redirected_to(conn) == ~p"/auth/relay/github"
      assert get_session(conn, :auth_relay_target) == %{host: @preview, state: state}

      github = conn |> recycle() |> get(~p"/auth/relay/github") |> redirected_to()
      %URI{host: "github.com", path: "/login/oauth/authorize", query: query} = URI.parse(github)
      query = URI.decode_query(query)

      assert query["client_id"] == "relay-client-id"
      assert query["redirect_uri"] =~ ~r|/auth/relay/github/callback\z|
    end

    test "does not start GitHub sign-in without the confirm step", %{conn: conn} do
      conn = get(conn, ~p"/auth/relay/github")

      assert response(conn, 400)
      assert get_resp_header(conn, "location") == []
    end

    test "sends the user back to the preview over https with a code", %{state: state} do
      conn =
        relay_callback(
          %{auth_relay_target: %{host: @preview, state: state}},
          {:ueberauth_auth, github_auth()}
        )

      %URI{scheme: "https", host: @preview, path: "/auth/relay/accept", query: query} =
        URI.parse(redirected_to(conn))

      assert {:ok, %{github_id: 77_001, username: "octo"}} =
               AuthRelay.redeem_code(URI.decode_query(query)["code"], @preview, state)

      # The relay itself stays signed out, and the target is used up.
      refute get_session(conn, :current_user_id)
      refute get_session(conn, :auth_relay_target)
    end

    test "reports a GitHub failure to the preview", %{state: state} do
      failure = %Ueberauth.Failure{
        errors: [%Ueberauth.Failure.Error{message_key: "access_denied"}]
      }

      conn =
        relay_callback(
          %{auth_relay_target: %{host: @preview, state: state}},
          {:ueberauth_failure, failure}
        )

      assert redirected_to(conn) == "https://#{@preview}/auth/relay/accept?error=github"
    end

    test "a callback without a confirmed target goes nowhere" do
      conn = relay_callback(%{}, {:ueberauth_auth, github_auth()})

      assert response(conn, 400)
      assert get_resp_header(conn, "location") == []
    end

    test "is off unless configured", %{conn: conn, state: state} do
      Application.put_env(:reviews, :auth_relay,
        url: @relay_url,
        secret: String.duplicate("s", 64)
      )

      assert conn |> get(~p"/auth/relay?#{[host: @preview, state: state]}") |> response(404)
    end
  end

  describe "preview" do
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
