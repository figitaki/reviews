defmodule ReviewsWeb.AuthRelayController do
  @moduledoc """
  GitHub sign-in for preview apps through a relay. See `Reviews.AuthRelay`.

  On the relay (production, when `Reviews.AuthRelay.relay?/0`):

    * `GET /auth/relay?host=<preview host>&state=<state>`: asks the user to
      confirm the preview they are signing in to. Any host other than
      `reviews-pr-<digits>.fly.dev` gets a 400 and no redirect.
    * `POST /auth/relay`: keeps the host and state in the session and starts
      GitHub sign-in with the preview OAuth app.
    * `GET /auth/relay/github/callback`: GitHub returns here. Sends the user to
      `https://<host>/auth/relay/accept?code=<code>`. It does not sign the
      user in to the relay.

  On a preview (when `Reviews.AuthRelay.client?/0` and its host is a preview
  host):

    * `GET /auth/relay/accept?code=<code>`: redeems the code and signs the
      user in, then returns to the page sign-in started from.

  `GET /auth/github` on a preview starts this flow (`ReviewsWeb.AuthController`).
  """
  use ReviewsWeb, :controller

  require Logger

  alias Reviews.AuthRelay
  alias ReviewsWeb.AuthController

  plug :require_relay when action in [:confirm, :start, :request, :callback]
  plug :require_target when action in [:request]
  plug :require_preview when action in [:accept]
  plug Ueberauth, providers: [:github_relay]

  def confirm(conn, params) do
    with {:ok, host, state} <- target_params(params) do
      render(conn, :confirm, host: host, state: state)
    else
      :error -> bad_target(conn)
    end
  end

  def start(conn, params) do
    with {:ok, host, state} <- target_params(params) do
      conn
      |> put_session(:auth_relay_target, %{host: host, state: state})
      |> redirect(to: ~p"/auth/relay/github")
    else
      :error -> bad_target(conn)
    end
  end

  # Ueberauth handles GET /auth/relay/github and redirects to GitHub, so this
  # action only runs if it could not.
  def request(conn, _params), do: bad_target(conn)

  def callback(conn, _params) do
    target = get_session(conn, :auth_relay_target)
    conn = delete_session(conn, :auth_relay_target)

    case {target, conn.assigns} do
      {%{host: host, state: state}, %{ueberauth_auth: auth}} ->
        code = AuthRelay.issue_code(host, state, AuthController.github_attrs(auth))
        redirect(conn, external: accept_url(host, code: code))

      {%{host: host}, %{ueberauth_failure: failure}} ->
        Logger.warning("GitHub OAuth for preview relay failed: #{inspect(failure.errors)}")
        redirect(conn, external: accept_url(host, error: "github"))

      _ ->
        bad_target(conn)
    end
  end

  def accept(conn, params) do
    state = get_session(conn, :auth_relay_state)
    conn = delete_session(conn, :auth_relay_state)

    with {:ok, code} <- Map.fetch(params, "code"),
         {:ok, attrs} <- AuthRelay.redeem_code(code, conn.host, state) do
      AuthController.sign_in(conn, attrs)
    else
      error ->
        Logger.warning("Preview relay sign-in failed: #{inspect(error)}")

        conn
        |> put_flash(:error, "GitHub sign-in failed. Try again.")
        |> AuthController.redirect_back()
    end
  end

  # The relay builds the URL itself: always https, always the accept path.
  # `host` has passed `AuthRelay.allowed_host?/1`.
  defp accept_url(host, query),
    do: "https://#{host}/auth/relay/accept?" <> URI.encode_query(query)

  defp target_params(%{"host" => host, "state" => state}) do
    if AuthRelay.allowed_host?(host) and AuthRelay.valid_state?(state),
      do: {:ok, host, state},
      else: :error
  end

  defp target_params(_params), do: :error

  defp bad_target(conn) do
    conn
    |> put_status(:bad_request)
    |> text("This sign-in link is not valid. Start again from the preview's Sign in button.")
  end

  # GitHub sign-in starts only after the confirm step stored a target.
  defp require_target(conn, _opts) do
    case get_session(conn, :auth_relay_target) do
      %{host: _, state: _} -> conn
      _ -> conn |> bad_target() |> halt()
    end
  end

  defp require_relay(conn, _opts) do
    if AuthRelay.relay?(), do: conn, else: not_found(conn)
  end

  # Production never accepts relay codes, even if misconfigured as a client:
  # its host is not a preview host.
  defp require_preview(conn, _opts) do
    if AuthRelay.client?() and AuthRelay.allowed_host?(conn.host),
      do: conn,
      else: not_found(conn)
  end

  defp not_found(conn), do: conn |> put_status(:not_found) |> text("Not Found") |> halt()
end
