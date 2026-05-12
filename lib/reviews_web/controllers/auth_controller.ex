defmodule ReviewsWeb.AuthController do
  @moduledoc """
  GitHub OAuth via `ueberauth_github`.

  Routes:
    * `GET /auth/github`           — kicks off the OAuth flow (handled by Ueberauth plug)
    * `GET /auth/github/callback`  — receives the callback and creates the session

  Anonymous viewing is allowed throughout the app; only commenting requires
  a session, enforced higher up.
  """
  use ReviewsWeb, :controller

  plug :require_oauth_configured when action in [:request]
  plug Ueberauth

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

  def request(conn, _params) do
    # Ueberauth handles the redirect; if we ever land here it means the
    # request couldn't be built (e.g. missing client_id).
    conn
    |> put_flash(:error, "GitHub login is not configured.")
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    conn
    |> put_flash(:error, "GitHub authentication failed.")
    |> redirect(to: ~p"/")
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
        |> redirect(to: ~p"/")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not create user from GitHub profile.")
        |> redirect(to: ~p"/")
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
