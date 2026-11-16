defmodule ReviewsWeb.AuthControllerTest do
  use ReviewsWeb.ConnCase

  alias ReviewsWeb.AuthController

  @moduletag :capture_log

  defp put_oauth_config(client_id) do
    original = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)

    Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
      client_id: client_id,
      client_secret: client_id
    )

    on_exit(fn ->
      Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, original)
    end)
  end

  describe "GET /auth/github when not configured" do
    setup do
      put_oauth_config(nil)
      :ok
    end

    test "redirects home with a configuration error flash", %{conn: conn} do
      conn = get(conn, ~p"/auth/github")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "GitHub OAuth is not configured"
    end
  end

  describe "return_to after sign-in" do
    setup do
      put_oauth_config("test-client-id")
      :ok
    end

    # Starts sign-in with `params`, then comes back to the callback without a
    # GitHub code, which Ueberauth reports as a failure. Returns where the
    # callback sends the browser.
    defp round_trip(conn, params) do
      conn = get(conn, ~p"/auth/github?#{params}")
      assert redirected_to(conn) =~ "https://github.com/login/oauth/authorize"

      conn |> recycle() |> get(~p"/auth/github/callback") |> redirected_to()
    end

    test "returns to the local page sign-in started from", %{conn: conn} do
      assert round_trip(conn, return_to: "/r/abc123?patchset=2&thread=5") ==
               "/r/abc123?patchset=2&thread=5"

      assert round_trip(build_conn(), return_to: "/settings") == "/settings"
    end

    test "falls back to home without a return_to", %{conn: conn} do
      assert round_trip(conn, []) == "/"
    end

    for unsafe <- [
          "https://evil.example/r/abc",
          "//evil.example/r/abc",
          "/\\evil.example",
          "\\\\evil.example",
          "/\t/evil.example",
          "/\n/evil.example",
          "/%09/evil.example",
          "/r/abc\\..",
          "javascript:alert(1)",
          "evil.example",
          ""
        ] do
      test "falls back to home for unsafe return_to #{inspect(unsafe)}", %{conn: conn} do
        assert round_trip(conn, return_to: unquote(unsafe)) == "/"
      end
    end

    test "an unsafe return_to replaces an earlier safe one", %{conn: conn} do
      conn = get(conn, ~p"/auth/github?#{[return_to: "/r/abc123"]}")

      assert conn |> recycle() |> round_trip(return_to: "//evil.example") == "/"
    end

    test "a successful sign-in returns to the stored page", %{conn: conn} do
      auth = %Ueberauth.Auth{
        uid: 55_001,
        info: %Ueberauth.Auth.Info{nickname: "carey", image: nil, email: "carey@example.com"}
      }

      conn =
        conn
        |> init_test_session(%{return_to: "/r/abc123?patchset=2"})
        |> bypass_through(ReviewsWeb.Router, [:browser])
        |> get(~p"/auth/github/callback")
        |> assign(:ueberauth_auth, auth)
        |> AuthController.callback(%{})

      assert redirected_to(conn) == "/r/abc123?patchset=2"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Signed in as carey."
      assert get_session(conn, :current_user_id)
      refute get_session(conn, :return_to)
    end
  end
end
