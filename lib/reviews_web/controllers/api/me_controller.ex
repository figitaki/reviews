defmodule ReviewsWeb.Api.MeController do
  @moduledoc """
  CLI-facing `/api/v1/me` endpoint. Returns the user behind the current
  bearer token. Powers `reviews whoami`.
  """
  use ReviewsWeb, :controller

  def show(conn, _params) do
    user = conn.assigns.current_user
    json(conn, %{username: user.username, email: user.email})
  end
end
