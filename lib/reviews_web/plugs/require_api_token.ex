defmodule ReviewsWeb.Plugs.RequireApiToken do
  @moduledoc """
  Looks for `Authorization: Bearer <token>` and assigns `:current_user` and
  `:current_identity`.
  Halts with 401 JSON if missing/invalid.
  """
  import Plug.Conn

  alias Reviews.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with [raw] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- raw,
         {:ok, %{user: user, identity: identity}} <- Accounts.authenticate_token(token) do
      conn
      |> assign(:current_user, user)
      |> assign(:current_identity, identity)
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{errors: %{detail: "Unauthorized"}}))
        |> halt()
    end
  end
end
