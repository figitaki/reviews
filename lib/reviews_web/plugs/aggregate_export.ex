defmodule ReviewsWeb.Plugs.AggregateExport do
  @moduledoc "Reject aggregate credentials on other paths; authenticate before request logging/parsing."
  import Plug.Conn
  alias Reviews.Analytics.Credential
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
        error(conn, 405, "Method not allowed")

      conn.query_string != "" ->
        error(conn, 400, "Parameters are not supported")

      get_req_header(conn, "content-length") not in [[], ["0"]] or
          get_req_header(conn, "transfer-encoding") != [] ->
        error(conn, 400, "Body is not supported")

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
        |> error(403, "Credential scope denied")

      false ->
        conn
    end
  end

  defp authenticate(conn, ["Bearer " <> token]) do
    case Credential.authenticate(token) do
      {:ok, digest} -> assign(conn, :analytics_export_digest, digest)
      _ -> unauthorized(conn)
    end
  end

  defp authenticate(conn, _), do: unauthorized(conn)

  defp unauthorized(conn) do
    case Reviews.Analytics.Cache.admit_rejection() do
      :ok -> error(conn, 401, "Unauthorized")
      :limited -> error(conn, 429, "Rate limit exceeded")
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

  defp error(conn, status, message) do
    conn |> put_status(status) |> Phoenix.Controller.json(%{errors: %{detail: message}}) |> halt()
  end
end
