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

  On a preview app configured as a relay client (`Reviews.AuthRelay.client?/0`),
  `GET /auth/github` sends the user to the sign-in relay instead of GitHub.

  On the relay (production), `GET /auth/github?relay=1` after
  `POST /auth/relay` is a relay sign-in: the relay target in the signed
  session is bound to this sign-in's OAuth state. The callback then hands the
  sign-in to `ReviewsWeb.AuthRelayController.finish/2` and signs no one in to
  production. Every other sign-in drops any relay target and works as before.
  See `ReviewsWeb.AuthRelayController`.
  """
  use ReviewsWeb, :controller

  plug :store_return_to when action in [:request]
  plug :redirect_to_relay when action in [:request]
  plug :require_oauth_configured when action in [:request]
  plug :bind_relay_target when action in [:request]
  plug Ueberauth, providers: [:github]

  require Logger

  alias Reviews.Accounts
  alias Reviews.AuthRelay

  defp redirect_to_relay(conn, _opts) do
    if AuthRelay.client?() do
      state = AuthRelay.new_state()
      query = URI.encode_query(host: conn.host, state: state)

      conn
      |> put_session(:auth_relay_state, state)
      |> redirect(external: AuthRelay.relay_url() <> "/auth/relay?" <> query)
      |> halt()
    else
      conn
    end
  end

  # Ueberauth picks the OAuth state while it builds the GitHub redirect, so
  # the binding is written just before the response goes out.
  defp bind_relay_target(conn, _opts) do
    case {conn.params["relay"], get_session(conn, :auth_relay_target)} do
      {"1", %{host: _, state: _} = target} when not is_map_key(target, :oauth_state) ->
        if AuthRelay.relay?() do
          register_before_send(conn, fn conn ->
            oauth_state = conn.private[:ueberauth_state_param]
            put_session(conn, :auth_relay_target, Map.put(target, :oauth_state, oauth_state))
          end)
        else
          delete_session(conn, :auth_relay_target)
        end

      _ ->
        delete_session(conn, :auth_relay_target)
    end
  end

  # :none for a normal sign-in, {:ok, target} for a relay sign-in, :refuse
  # when a relay target is in the session but not for this OAuth state.
  defp relay_sign_in(conn, params) do
    case get_session(conn, :auth_relay_target) do
      nil ->
        :none

      %{oauth_state: oauth_state} = target when is_binary(oauth_state) ->
        state = params["state"]

        if AuthRelay.relay?() and is_binary(state) and
             Plug.Crypto.secure_compare(oauth_state, state),
           do: {:ok, target},
           else: :refuse

      _ ->
        :refuse
    end
  end

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

  @doc false
  def redirect_back(conn) do
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

  def callback(conn, params) do
    relay = relay_sign_in(conn, params)
    conn = delete_session(conn, :auth_relay_target)

    case relay do
      :none ->
        github_callback(conn)

      {:ok, target} ->
        ReviewsWeb.AuthRelayController.finish(conn, target)

      :refuse ->
        Logger.warning("Refused a GitHub callback whose state does not match the relay sign-in")

        conn
        |> put_flash(:error, "GitHub authentication failed.")
        |> redirect(to: ~p"/")
    end
  end

  defp github_callback(%{assigns: %{ueberauth_failure: failure}} = conn) do
    Logger.warning("GitHub OAuth failed: #{inspect(failure.errors)}")

    conn
    |> put_flash(:error, "GitHub authentication failed.")
    |> redirect_back()
  end

  defp github_callback(%{assigns: %{ueberauth_auth: auth}} = conn) do
    sign_in(conn, github_attrs(auth))
  end

  # The helpers below are shared with ReviewsWeb.AuthRelayController.

  @doc false
  def github_attrs(%Ueberauth.Auth{} = auth) do
    %{
      github_id: auth.uid |> to_integer(),
      username: auth.info.nickname || auth.info.name,
      avatar_url: auth.info.image,
      email: auth.info.email
    }
  end

  @doc false
  def sign_in(conn, attrs) do
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
