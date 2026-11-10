defmodule ReviewsWeb.Api.CapabilityController do
  @moduledoc """
  `GET /api/v1/capabilities` — unauthenticated feature discovery for the CLI.

  Older servers do not have this route; the CLI treats a 404 here as "code
  storage disabled". The payload contains configuration booleans and limits
  only — never storage keys or credentials.

  Note the `required` policy is enforced by the CLI (abort before creating
  anything); the server keeps accepting snapshot-less pushes so older CLIs
  continue to work.
  """
  use ReviewsWeb, :controller

  alias Reviews.CodeStorage

  @doc "GET /api/v1/capabilities"
  def show(conn, _params) do
    json(conn, CodeStorage.capabilities())
  end
end
