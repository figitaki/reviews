defmodule ReviewsWeb.Plugs.CanonicalHost do
  @moduledoc """
  301-redirects requests whose host is not the canonical host.

  The canonical host is read from the endpoint's `:url` config (`PHX_HOST`).
  When unset (dev/test) the plug is a no-op, so it only acts in prod once
  `PHX_HOST` is set to `reviews.figitaki.dev`. This is what retires the legacy
  `reviews-dev.fly.dev` hostname after the domain cutover.
  """
  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case canonical_host() do
      nil ->
        conn

      host when conn.host == host ->
        conn

      host ->
        location = "https://" <> host <> request_path_with_query(conn)

        conn
        |> put_resp_header("location", location)
        |> send_resp(301, "")
        |> halt()
    end
  end

  defp canonical_host do
    :reviews
    |> Application.get_env(ReviewsWeb.Endpoint, [])
    |> Keyword.get(:url, [])
    |> Keyword.get(:host)
    |> normalize()
  end

  # `phx.gen` defaults :host to "example.com" in dev/test config; treat that
  # placeholder as "no canonical host" so the plug stays inert outside prod.
  defp normalize(host) when host in [nil, "", "localhost", "example.com"], do: nil
  defp normalize(host), do: host

  defp request_path_with_query(%Plug.Conn{request_path: path, query_string: ""}), do: path

  defp request_path_with_query(%Plug.Conn{request_path: path, query_string: qs}),
    do: path <> "?" <> qs
end
