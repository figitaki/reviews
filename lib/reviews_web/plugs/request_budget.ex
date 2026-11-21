defmodule ReviewsWeb.Plugs.RequestBudget do
  @moduledoc "Cheap admission before Phoenix dispatch, including socket establishment."
  import Plug.Conn
  alias Reviews.{Errors, RateLimiter}
  alias ReviewsWeb.ApiErrors
  @defaults [requests: 300, writes: 60, uploads: 20, sockets: 60, owners: 60]

  def init(opts), do: opts

  def call(conn, opts) do
    opts = Keyword.merge(Application.get_env(:reviews, __MODULE__, []), opts)
    client = conn |> client_ip(Keyword.get(opts, :trust_fly_client_ip, false)) |> bucket()
    policies = [:requests | policies(conn)]

    Enum.reduce_while(policies, conn, fn policy, conn ->
      case allow?(policy, client, opts) do
        true -> {:cont, conn}
        false -> {:halt, reject(conn)}
      end
    end)
  end

  @doc """
  The client address for budgets. With `trust?` (on Fly, where the endpoint
  listens on IPv4 only and only Fly Proxy reaches it over IPv4), a single valid
  `Fly-Client-IP` wins; a missing, repeated or invalid header falls back to the
  socket peer.
  """
  def client_ip(conn, trust?) do
    with true <- trust?,
         [value] when byte_size(value) <= 45 <- get_req_header(conn, "fly-client-ip"),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(value)) do
      ip
    else
      _ -> conn.remote_ip
    end
  end

  @doc """
  The budget key for an address. One IPv6 subscriber usually holds a whole /64,
  so IPv6 addresses share a budget per /64; IPv4-mapped IPv6 counts as its IPv4.
  """
  def bucket({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)}

  def bucket({a, b, c, d, _, _, _, _}), do: {a, b, c, d, 0, 0, 0, 0}
  def bucket(ip), do: ip

  def allow?(policy, client, opts \\ []) do
    opts = Keyword.merge(Application.get_env(:reviews, __MODULE__, []), opts)
    limits = Keyword.merge(@defaults, Keyword.get(opts, :limits, []))

    RateLimiter.check(
      policy,
      client,
      Keyword.fetch!(limits, policy),
      Keyword.get(opts, :table, RateLimiter)
    ) == :ok
  end

  def reject(conn) do
    conn
    |> put_oauth_cors()
    |> put_resp_header("retry-after", "60")
    |> put_resp_content_type("application/json")
    |> send_resp(429, JSON.encode!(ApiErrors.detail(:rate_limited, Errors.detail(:rate_limited))))
    |> halt()
  end

  # Phoenix.Router decodes each segment before matching routes.
  def upload?(conn), do: upload_path?(decoded_path(conn))
  def api_write?(conn), do: api_write_path?(decoded_path(conn))
  defp decoded_path(conn), do: %{conn | path_info: Enum.map(conn.path_info, &URI.decode/1)}

  # The router allows cross-origin reads of OAuth endpoints, but this response
  # is sent before it runs; match it so browser clients can read the 429.
  defp put_oauth_cors(conn) do
    case decoded_path(conn).path_info do
      [first | _] when first in ["oauth", ".well-known"] ->
        conn
        |> put_resp_header("access-control-allow-origin", "*")
        |> put_resp_header("access-control-expose-headers", "retry-after")

      _ ->
        conn
    end
  end

  defp upload_path?(%{method: "POST", path_info: ["api", "v1", "reviews"]}), do: true

  defp upload_path?(%{method: "POST", path_info: ["api", "v1", "reviews", _, "patchsets"]}),
    do: true

  defp upload_path?(_), do: false

  defp api_write_path?(%{method: method, path_info: ["api", "v1" | _]})
       when method in ["POST", "PUT", "PATCH", "DELETE"], do: true

  defp api_write_path?(_), do: false

  defp policies(%{path_info: ["live" | _]}), do: [:sockets]

  defp policies(conn) do
    cond do
      upload?(conn) -> [:writes, :uploads]
      conn.method in ["POST", "PUT", "PATCH", "DELETE"] -> [:writes]
      true -> []
    end
  end
end
