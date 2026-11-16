defmodule ReviewsWeb.Plugs.RequireApiToken do
  @moduledoc """
  Looks for `Authorization: Bearer <token>` and assigns `:current_user` and
  `:current_identity`.
  Halts with 401 JSON if missing/invalid.
  """
  import Plug.Conn

  alias Reviews.Accounts

  def init(opts), do: opts

  # Only this plug writes the private marker, after successful authentication.
  # Caller-supplied assigns alone must never bypass authentication.
  def call(%{private: %{reviews_api_authenticated: {user, identity}}} = conn, _opts) do
    conn |> assign(:current_user, user) |> assign(:current_identity, identity)
  end

  def call(conn, _opts) do
    with [raw] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- raw,
         true <- token != "",
         {:ok, %{user: user, identity: identity}} <- Accounts.authenticate_token(token) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_identity, identity)
      |> put_private(:reviews_api_authenticated, {user, identity})
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, JSON.encode!(%{errors: %{detail: "Unauthorized"}}))
        |> halt()
    end
  end
end
