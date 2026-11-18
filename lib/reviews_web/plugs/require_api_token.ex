defmodule ReviewsWeb.Plugs.RequireApiToken do
  @moduledoc """
  Looks for `Authorization: Bearer <token>` and assigns `:current_user`,
  `:current_identity`, and `:current_principal` (a `Reviews.Principal` with
  every scope). The token is an API token minted in Settings, or an access
  token from `reviews login` (`Reviews.OAuth.CLI`, whose only scope is the
  CLI API); both act as the person's identity and are not scoped further.
  Halts with 401 JSON if missing/invalid. An invalid token also gets a
  `WWW-Authenticate` challenge with `invalid_token`, so the CLI knows to
  refresh it.

  `ReviewsWeb.Plugs.BodyBudget` runs this plug for API writes before their
  bodies are parsed. The router's run reuses that result from a private
  marker, so a token (and a CLI token's DPoP proof) is checked once.
  """
  import Plug.Conn

  alias Reviews.Accounts
  alias Reviews.OAuth

  def init(opts), do: opts

  # Only this plug writes the private marker, after successful authentication.
  # Caller-supplied assigns alone must never bypass authentication.
  def call(%{private: %{reviews_api_authenticated: {user, identity, principal}}} = conn, _opts) do
    conn
    |> assign(:current_user, user)
    |> assign(:current_identity, identity)
    |> assign(:current_principal, principal)
  end

  def call(conn, _opts) do
    with [raw] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- raw,
         true <- token != "",
         {:ok, %{user: user, identity: identity}} <- authenticate(conn, raw, token) do
      principal = Reviews.Principal.new(identity, :api_token, user)

      conn
      |> assign(:current_user, user)
      |> assign(:current_identity, identity)
      |> assign(:current_principal, principal)
      |> put_private(:reviews_api_authenticated, {user, identity, principal})
    else
      [_raw] ->
        unauthorized(conn, ~s(Bearer error="invalid_token"))

      {:error, _reason} ->
        unauthorized(conn, ~s(Bearer error="invalid_token"))

      _ ->
        unauthorized(conn, "Bearer")
    end
  end

  # An API token, else a CLI access token. Preview environments seed API
  # tokens of any shape, so the prefix doesn't decide.
  defp authenticate(conn, raw, token) do
    case Accounts.authenticate_token(token) do
      {:ok, _} = ok ->
        ok

      {:error, _} ->
        OAuth.authenticate_cli_token(%{
          authorization: raw,
          dpop: get_req_header(conn, "dpop"),
          method: conn.method,
          path: conn.request_path
        })
    end
  end

  defp unauthorized(conn, challenge) do
    conn
    |> put_resp_header("www-authenticate", challenge)
    |> put_resp_content_type("application/json")
    |> send_resp(401, JSON.encode!(ReviewsWeb.ApiErrors.detail(:unauthorized, "Unauthorized")))
    |> halt()
  end
end
