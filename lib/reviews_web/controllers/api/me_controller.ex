defmodule ReviewsWeb.Api.MeController do
  @moduledoc """
  CLI-facing `/api/v1/me` endpoint. Returns the user behind the current
  bearer token. Powers `reviews whoami`.
  """
  use ReviewsWeb, :controller

  def show(conn, _params) do
    user = conn.assigns.current_user
    identity = conn.assigns.current_identity

    json(conn, %{
      username: user.username,
      email: user.email,
      identity: %{
        id: identity.id,
        kind: identity.kind,
        handle: identity.handle,
        username: identity.handle,
        display_name: identity.display_name,
        avatar_url: identity.avatar_url
      }
    })
  end
end
