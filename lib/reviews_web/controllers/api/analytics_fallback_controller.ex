defmodule ReviewsWeb.Api.AnalyticsFallbackController do
  use ReviewsWeb, :controller

  def call(conn, {:error, :unauthorized}), do: respond(conn, 401, "Unauthorized")
  def call(conn, {:error, :rate_limited}), do: respond(conn, 429, "Rate limit exceeded")
  def call(conn, {:error, :unavailable}), do: respond(conn, 503, "Snapshot unavailable")

  defp respond(conn, status, detail) do
    conn
    |> put_resp_header("retry-after", "60")
    |> put_status(status)
    |> json(%{errors: %{detail: detail}})
  end
end
