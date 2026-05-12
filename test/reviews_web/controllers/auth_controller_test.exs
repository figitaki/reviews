defmodule ReviewsWeb.AuthControllerTest do
  use ReviewsWeb.ConnCase

  describe "GET /auth/github when not configured" do
    setup do
      original = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)

      Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth,
        client_id: nil,
        client_secret: nil
      )

      on_exit(fn ->
        Application.put_env(:ueberauth, Ueberauth.Strategy.Github.OAuth, original)
      end)

      :ok
    end

    test "redirects home with a configuration error flash", %{conn: conn} do
      conn = get(conn, ~p"/auth/github")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "GitHub OAuth is not configured"
    end
  end
end
