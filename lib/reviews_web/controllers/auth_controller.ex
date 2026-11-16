defmodule ReviewsWeb.AuthController do
  @moduledoc """
  GitHub OAuth via `ueberauth_github`.

  Routes:
    * `GET /auth/github`           — kicks off the OAuth flow (handled by Ueberauth plug)
    * `GET /auth/github/callback`  — receives the callback and creates the session

  Anonymous viewing is allowed throughout the app; only commenting requires
  a session, enforced higher up.

  Sign-in links pass `?return_to=<local path>`; the request phase keeps it in
  the session and the callback redirects there. Anything other than a local
  path falls back to `/`.
  """
  use ReviewsWeb, :controller

  plug :require_oauth_configured when action in [:request]
  plug :store_return_to when action in [:request]
  plug Ueberauth

  require Logger

  alias Reviews.Accounts

  defp require_oauth_configured(conn, _opts) do
    client_id = Application.get_env(:ueberauth, Ueberauth.Strategy.Github.OAuth)[:client_id]

    if client_id in [nil, ""] do
      conn
      |> put_flash(
        :error,
        "GitHub OAuth is not configured. Set GITHUB_CLIENT_ID and GITHUB_CLIENT_SECRET (see .env.example)."
      )
      |> redirect(to: ~p"/")
      |> halt()
    else
      conn
    end
  end

  defp store_return_to(conn, _opts) do
    case safe_return_to(conn.params["return_to"]) do
      nil -> delete_session(conn, :return_to)
      path -> put_session(conn, :return_to, path)
    end
  end

  # Only same-site paths: "/..." but not "//host" (scheme-relative), no
  # backslashes ("/\host" is scheme-relative to browsers) and no control
  # characters, which browsers strip ("/\t/host" becomes "//host"). This is
  # also everything `redirect(to:)` refuses, so the callback cannot crash.
  defp safe_return_to("/" <> _ = path) do
    if String.starts_with?(path, "//") or String.contains?(path, ["\\", "/%09"]) or
         String.match?(path, ~r/[\x00-\x1f\x7f]/) do
      nil
    else
      path
    end
  end

  defp safe_return_to(_), do: nil

  defp redirect_back(conn) do
    to = get_session(conn, :return_to) || ~p"/"

    conn
    |> delete_session(:return_to)
    |> redirect(to: to)
  end

  def request(conn, _params) do
    # Ueberauth handles the redirect; if we ever land here it means the
    # request couldn't be built (e.g. missing client_id).
    conn
    |> put_flash(:error, "GitHub login is not configured.")
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    Logger.warning("GitHub OAuth failed: #{inspect(failure.errors)}")

    conn
    |> put_flash(:error, "GitHub authentication failed.")
    |> redirect_back()
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    attrs = %{
      github_id: auth.uid |> to_integer(),
      username: auth.info.nickname || auth.info.name,
      avatar_url: auth.info.image,
      email: auth.info.email
    }

    case Accounts.upsert_from_github(attrs) do
      {:ok, user} ->
        conn
        |> put_session(:current_user_id, user.id)
        |> configure_session(renew: true)
        |> put_flash(:info, "Signed in as #{user.username}.")
        |> redirect_back()

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not create user from GitHub profile.")
        |> redirect_back()
    end
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/")
  end

  # GitHub UIDs come through as integers or strings depending on strategy version.
  defp to_integer(n) when is_integer(n), do: n

  defp to_integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end
end
