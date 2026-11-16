defmodule ReviewsWeb.OAuthDiscoveryController do
  @moduledoc """
  Discovery for the Reviews OAuth issuer: authorization server metadata
  (RFC 8414) and the protected resource metadata (RFC 9728) of each enabled
  `Reviews.OAuth.Resource`, as gatekeep builds them (`Reviews.OAuth`).

  A resource's metadata is served at the well-known URL with the resource's
  path appended (RFC 9728 §3.1): `/.well-known/oauth-protected-resource` for
  a resource at the root, `/.well-known/oauth-protected-resource/mcp` for one
  at `/mcp`.
  """
  use ReviewsWeb, :controller

  alias Reviews.OAuth

  def authorization_server(conn, _params) do
    cached_json(conn, OAuth.authorization_server_metadata())
  end

  def protected_resource(conn, _params) do
    path = String.trim_trailing(conn.request_path, "/")

    if metadata = OAuth.protected_resource_metadata(path) do
      cached_json(conn, metadata)
    else
      conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp cached_json(conn, body) do
    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> json(body)
  end
end
