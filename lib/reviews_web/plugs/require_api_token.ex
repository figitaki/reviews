defmodule ReviewsWeb.Plugs.RequireApiToken do
  @moduledoc """
  Looks for `Authorization: Bearer <token>` and assigns `:current_user` and
  `:current_identity`. The token is an API token minted in Settings, or an
  access token from `reviews login` (`Reviews.OAuth.CLI`); both act as the
  person's identity.
  Halts with 401 JSON if missing/invalid. An invalid token also gets a
  `WWW-Authenticate` challenge with `invalid_token`, so the CLI knows to
  refresh it.
  """
  import Plug.Conn

  alias Reviews.Accounts
  alias Reviews.OAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    with [raw] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- raw,
         {:ok, %{user: user, identity: identity}} <- authenticate(conn, raw, token) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_identity, identity)
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
    |> send_resp(401, JSON.encode!(%{errors: %{detail: "Unauthorized"}}))
    |> halt()
  end
end
