defmodule ReviewsWeb.Plugs.ReviewPageRateLimit do
  @moduledoc """
  Limits anonymous HTTP requests to review pages (`/r/:slug/...`) per client
  IP. Each such request renders the page and builds its link preview, so a
  flood costs CPU in proportion (issue #265).

  Signed-in requests (a `current_user`) pass untouched, so this plug must run
  after `ReviewsWeb.Plugs.FetchCurrentUser`. Over the limit the response is
  `429` with `retry-after` and a short plain-text body.

  Crawlers are not exempt by User-Agent, which anyone can send. The default,
  120 requests per 60 seconds, is far above what an unfurler needs (Slackbot,
  Discordbot and Twitterbot fetch a URL once or twice) and above a person
  reloading a page.

  A client is an IPv4 address, or the /64 prefix of an IPv6 address: one host
  usually holds a whole /64 and can send each request from a new address in
  it. An IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) counts as its IPv4
  address.

  Counts are fixed windows in ETS, local to each node. The table is bounded:
  a sweep drops windows that have ended, and at `max_entries` new clients
  share one overflow bucket until the next sweep. Within a window, clients
  already in the table keep their own counts.

  The overflow bucket has its own, higher limit, `overflow_limit`, so total
  work stays bounded while the table is full. An attacker who fills the table
  (`max_entries` distinct IPv4 addresses or /64s in one window) can, until a
  sweep drops that window's entries: spend their own per-client allowance from each of those
  clients, and use up the overflow bucket so that new anonymous visitors,
  link-preview crawlers included, get 429 until then. They
  cannot raise the limit of any client already in the table, cannot affect
  signed-in people or other routes, and cannot make the table grow past
  `max_entries` or the overflow bucket allow more than `overflow_limit`
  requests per window.

  Configuration (`config :reviews, #{inspect(__MODULE__)}`):

    * `:limit` - requests per window per client IP (default 120)
    * `:overflow_limit` - requests per window shared by every new client while
      the table is full (default ten times `:limit`)
    * `:window_seconds` - window length (default 60)
    * `:max_entries` - hard cap on table entries (default 50_000)
    * `:client_ip` - `:remote_ip` (default) uses the socket peer; `{:header,
      name}` uses that request header when it holds exactly one valid IP, and
      the socket peer otherwise. Use a header only when the proxy in front
      sets it on every request, overwriting what the client sent.
  """
  @behaviour Plug

  import Plug.Conn

  @table ReviewsWeb.Plugs.ReviewPageRateLimit.Table
  @overflow :overflow
  @defaults [limit: 120, window_seconds: 60, max_entries: 50_000, client_ip: :remote_ip]

  ## Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{current_user: user}} = conn, _opts) when not is_nil(user),
    do: conn

  def call(conn, _opts) do
    config = config()

    case hit(client_ip(conn, config[:client_ip]), System.system_time(:second), config) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_resp_content_type("text/plain")
        |> send_resp(429, "Too many requests. Try again in #{retry_after} seconds.\n")
        |> halt()
    end
  end

  @doc """
  Counts one request from `ip` at `now` (Unix seconds). Returns `:ok`, or
  `{:error, retry_after_seconds}` when the client is over the limit.
  """
  def hit(ip, now, config \\ config()) do
    window = config[:window_seconds]
    index = div(now, window)
    key = bucket(client_key(ip), index, config[:max_entries])
    count = :ets.update_counter(@table, key, {2, 1}, {key, 0})

    if count <= limit(key, config) do
      :ok
    else
      {:error, max((index + 1) * window - now, 1)}
    end
  end

  defp limit({@overflow, _index}, config),
    do: config[:overflow_limit] || config[:limit] * 10

  defp limit(_key, config), do: config[:limit]

  # IPv4-mapped IPv6 counts as IPv4; other IPv6 by its /64 prefix.
  defp client_key({0, 0, 0, 0, 0, 0xFFFF, ab, cd}),
    do: {div(ab, 256), rem(ab, 256), div(cd, 256), rem(cd, 256)}

  defp client_key({a, b, c, d, _, _, _, _}), do: {:ipv6_64, a, b, c, d}
  defp client_key(ip), do: ip

  # A new client past the cap counts against the shared overflow bucket.
  defp bucket(ip, index, max_entries) do
    key = {ip, index}

    if :ets.member(@table, key) or :ets.info(@table, :size) < max_entries,
      do: key,
      else: {@overflow, index}
  end

  defp client_ip(conn, {:header, name}) do
    with [value] <- get_req_header(conn, name),
         charlist when is_list(charlist) <-
           value |> String.trim() |> :unicode.characters_to_list(),
         {:ok, ip} <- :inet.parse_strict_address(charlist) do
      ip
    else
      _ -> conn.remote_ip
    end
  end

  defp client_ip(conn, _), do: conn.remote_ip

  @doc "Deletes windows that ended before `now` (Unix seconds). Returns how many."
  def sweep(now \\ System.system_time(:second)) do
    current = div(now, config()[:window_seconds])
    :ets.select_delete(@table, [{{{:_, :"$1"}, :_}, [{:<, :"$1", current}], [true]}])
  end

  @doc "Forgets every count. For tests."
  def reset, do: :ets.delete_all_objects(@table)

  @doc false
  def config do
    Keyword.merge(@defaults, Application.get_env(:reviews, __MODULE__, []))
  end
end
