defmodule ReviewsWeb.AuthRelayController do
  @moduledoc """
  GitHub sign-in for preview apps through a relay. See `Reviews.AuthRelay`.

  On the relay (production, when `Reviews.AuthRelay.relay?/0`):

    * `GET /auth/relay?host=<preview host>&state=<state>`: asks the user to
      confirm the preview they are signing in to. Any host that is not a
      preview host (`Reviews.AuthRelay.allowed_host?/1`) gets a 400 and no
      redirect.
    * `POST /auth/relay`: keeps the host and state in the session and starts
      production's own GitHub sign-in with `/auth/github?relay=1`. That binds
      the target to the OAuth state of this sign-in.
    * GitHub returns to production's one callback, `/auth/github/callback`.
      When the OAuth state is the one bound to the relay target,
      `ReviewsWeb.AuthController.callback/2` calls `finish/2`, which sends the
      user to `https://<host>/auth/relay/accept?code=<code>` and does not sign
      anyone in to production.

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

  plug :require_relay when action in [:confirm, :start]
  plug :require_preview when action in [:accept]

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
      |> redirect(to: ~p"/auth/github?relay=1")
    else
      :error -> bad_target(conn)
    end
  end

  @doc """
  Finishes a relay sign-in in production's GitHub callback, once the callback
  has matched the OAuth state to `target`. Sends the user back to the preview
  with a code, or with `error=github`. Never touches the production session's
  sign-in.
  """
  def finish(conn, %{host: host, state: state}) do
    case conn.assigns do
      %{ueberauth_auth: auth} ->
        code = AuthRelay.issue_code(host, state, AuthController.github_attrs(auth))
        redirect(conn, external: accept_url(host, code: code))

      %{ueberauth_failure: failure} ->
        Logger.warning("GitHub OAuth for preview relay failed: #{inspect(failure.errors)}")
        redirect(conn, external: accept_url(host, error: "github"))
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
