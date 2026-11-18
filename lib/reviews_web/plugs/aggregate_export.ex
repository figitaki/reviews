defmodule ReviewsWeb.Plugs.AggregateExport do
  @moduledoc """
  Reject aggregate credentials on other paths; authenticate before request
  logging/parsing. A valid credential assigns `:current_principal`, a
  `Reviews.Principal.aggregate_export/1` with no identity or scopes. Errors use
  the `Reviews.Errors` codes through `ReviewsWeb.ApiErrors`.
  """
  import Plug.Conn
  alias Reviews.Analytics.Credential
  alias Reviews.Principal
  @path "/api/v1/analytics/snapshot"

  def init(opts), do: opts

  def call(%{request_path: @path} = conn, _opts) do
    authorization = get_req_header(conn, "authorization")

    conn =
      conn
      |> private_headers()
      |> delete_req_header("authorization")
      |> delete_req_header("cookie")

    cond do
      conn.method != "GET" ->
        error(conn, :method_not_allowed)

      conn.query_string != "" ->
        error(conn, :invalid_request, "Parameters are not supported")

      get_req_header(conn, "content-length") not in [[], ["0"]] or
          get_req_header(conn, "transfer-encoding") != [] ->
        error(conn, :invalid_request, "Body is not supported")

      true ->
        authenticate(conn, authorization)
    end
  end

  def call(conn, _opts) do
    case Enum.any?(get_req_header(conn, "authorization"), &String.starts_with?(&1, "Bearer rva_")) do
      true ->
        conn
        |> private_headers()
        |> delete_req_header("authorization")
        |> error(:insufficient_scope, "Credential scope denied")

      false ->
        conn
    end
  end

  defp authenticate(conn, ["Bearer " <> token]) do
    case Credential.authenticate(token) do
      {:ok, digest} -> assign(conn, :current_principal, Principal.aggregate_export(digest))
      _ -> unauthorized(conn)
    end
  end

  defp authenticate(conn, _), do: unauthorized(conn)

  defp unauthorized(conn) do
    case Reviews.Analytics.Cache.admit_rejection() do
      :ok -> error(conn, :unauthorized, "Unauthorized")
      :limited -> error(conn, :rate_limited)
    end
  end

  defp private_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("pragma", "no-cache")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("content-security-policy", "default-src 'none'; frame-ancestors 'none'")
  end

  defp error(conn, reason, message \\ nil),
    do: conn |> ReviewsWeb.ApiErrors.render(reason, message) |> halt()
end
