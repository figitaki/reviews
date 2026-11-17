defmodule ReviewsWeb.OAuthDiscoveryController do
  @moduledoc """
  Discovery for the Reviews OAuth issuer: authorization server metadata
  (RFC 8414) and the protected resource metadata (RFC 9728) of each enabled
  `Reviews.OAuth.Resource`.

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

  def protected_resource(conn, params) do
    path = Enum.join(Map.get(params, "path", []), "/")

    metadata =
      OAuth.enabled_resources()
      |> Enum.find(&(resource_path(&1) == path))
      |> then(&(&1 && OAuth.protected_resource_metadata(&1)))

    if metadata do
      cached_json(conn, metadata)
    else
      conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  defp resource_path(resource) do
    (URI.parse(resource.resource()).path || "") |> String.trim("/")
  end

  defp cached_json(conn, body) do
    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> json(body)
  end
end
