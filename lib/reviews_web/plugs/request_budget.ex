defmodule ReviewsWeb.Plugs.RequestBudget do
  @moduledoc "Cheap admission before Phoenix dispatch, including socket establishment."
  import Plug.Conn
  alias Reviews.RateLimiter
  @defaults [requests: 300, writes: 60, uploads: 20, sockets: 60, owners: 60]

  def init(opts), do: opts

  def call(conn, opts) do
    opts = Keyword.merge(Application.get_env(:reviews, __MODULE__, []), opts)
    client = client_ip(conn, Keyword.get(opts, :trusted_fly_proxy_peers, []))
    policies = [:requests | policies(conn)]

    Enum.reduce_while(policies, conn, fn policy, conn ->
      case allow?(policy, client, opts) do
        true -> {:cont, conn}
        false -> {:halt, reject(conn)}
      end
    end)
  end

  @doc "Only explicitly trusted socket peers may supply a single Fly-Client-IP."
  def client_ip(conn, trusted_peers) do
    with true <- conn.remote_ip in trusted_peers,
         [value] when byte_size(value) <= 45 <- get_req_header(conn, "fly-client-ip"),
         {:ok, ip} <- :inet.parse_strict_address(String.to_charlist(value)) do
      ip
    else
      _ -> conn.remote_ip
    end
  end

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
    |> put_resp_header("retry-after", "60")
    |> put_resp_content_type("application/json")
    |> send_resp(429, JSON.encode!(%{errors: %{detail: "Too many requests. Retry later."}}))
    |> halt()
  end

  # Phoenix.Router decodes each segment before matching routes.
  def upload?(conn), do: upload_path?(decoded_path(conn))
  def api_write?(conn), do: api_write_path?(decoded_path(conn))
  defp decoded_path(conn), do: %{conn | path_info: Enum.map(conn.path_info, &URI.decode/1)}

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
