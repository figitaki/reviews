defmodule ReviewsWeb.RequestBudgetTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias ReviewsWeb.Plugs.RequestBudget
  alias Reviews.RateLimiter

  setup do
    %{table: :ets.new(:limits, [:set, :public, write_concurrency: true])}
  end

  test "limits concurrent requests and expires without retaining client identifiers", %{
    table: table
  } do
    results =
      1..100
      |> Task.async_stream(fn _ -> RateLimiter.check(:requests, {1, 2, 3, 4}, 10, table, 0) end,
        max_concurrency: 20
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == :ok)) == 10
    assert RateLimiter.check(:requests, {1, 2, 3, 4}, 10, table, 59_999) == :limited
    assert RateLimiter.check(:requests, {1, 2, 3, 4}, 10, table, 60_000) == :ok
    for n <- 1..20_000, do: RateLimiter.check(:requests, n, 10, table, 60_000)
    assert :ets.info(table, :size) <= 16_384
  end

  test "missing table fails closed", %{table: table} do
    :ets.delete(table)
    assert RateLimiter.check(:requests, :client, 10, table) == :limited
  end

  test "trusts one valid Fly-Client-IP only when enabled, else uses the peer" do
    peer = {10, 0, 0, 7}
    conn = %{conn(:get, "/") | remote_ip: peer} |> put_req_header("fly-client-ip", "8.8.8.8")
    assert RequestBudget.client_ip(conn, false) == peer
    assert RequestBudget.client_ip(conn, true) == {8, 8, 8, 8}

    assert RequestBudget.client_ip(put_req_header(conn, "fly-client-ip", "2001:db8::1"), true) ==
             {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

    for value <- ["bad", "8.8.8.8, 1.1.1.1", "", "1.2.3", "8.8.8.8 ", String.duplicate("1", 46)] do
      assert RequestBudget.client_ip(put_req_header(conn, "fly-client-ip", value), true) == peer
    end

    assert RequestBudget.client_ip(%{conn | req_headers: []}, true) == peer
    two = %{conn | req_headers: [{"fly-client-ip", "8.8.8.8"}, {"fly-client-ip", "1.1.1.1"}]}
    assert RequestBudget.client_ip(two, true) == peer
  end

  test "buckets IPv6 by /64 and IPv4-mapped IPv6 as IPv4" do
    assert RequestBudget.bucket({8, 8, 8, 8}) == {8, 8, 8, 8}

    assert RequestBudget.bucket({0x2001, 0xDB8, 1, 2, 0xAAAA, 3, 4, 5}) ==
             {0x2001, 0xDB8, 1, 2, 0, 0, 0, 0}

    assert RequestBudget.bucket({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0404}) == {8, 8, 4, 4}
  end

  test "per-IP budgets follow Fly-Client-IP: one /64 shares, other clients do not", %{
    table: table
  } do
    opts = [table: table, limits: [requests: 1], trust_fly_client_ip: true]
    from = fn ip -> conn(:get, "/") |> put_req_header("fly-client-ip", ip) end

    refute RequestBudget.call(from.("2001:db8:0:1::1"), opts).halted
    assert RequestBudget.call(from.("2001:db8:0:1:ffff::2"), opts).status == 429
    refute RequestBudget.call(from.("2001:db8:0:2::1"), opts).halted
    refute RequestBudget.call(from.("203.0.113.1"), opts).halted
    refute RequestBudget.call(from.("203.0.113.2"), opts).halted

    # Without trust every request counts against the one socket peer.
    opts = Keyword.put(opts, :trust_fly_client_ip, false)
    other = :ets.new(:limits, [:set, :public])
    opts = Keyword.put(opts, :table, other)
    refute RequestBudget.call(from.("198.51.100.1"), opts).halted
    assert RequestBudget.call(from.("198.51.100.2"), opts).status == 429
  end

  test "429 is cheap, retryable, and precedes authentication and parsing", %{table: table} do
    opts = [table: table, limits: [requests: 1]]

    assert RequestBudget.call(conn(:post, "/api/v1/reviews", "invalid JSON"), opts).halted ==
             false

    rejected = RequestBudget.call(conn(:post, "/api/v1/reviews", "invalid JSON"), opts)
    assert rejected.status == 429
    assert rejected.halted
    assert get_resp_header(rejected, "retry-after") == ["60"]
    assert %{"error_code" => "rate_limited"} = JSON.decode!(rejected.resp_body)
    assert %Plug.Conn.Unfetched{} = rejected.body_params
    assert get_resp_header(rejected, "access-control-allow-origin") == []
  end

  test "an OAuth 429 keeps the router's CORS policy so browser clients can read it", %{
    table: table
  } do
    opts = [table: table, limits: [requests: 1]]
    RequestBudget.call(conn(:post, "/oauth/token"), opts)
    rejected = RequestBudget.call(conn(:post, "/oauth/token"), opts)

    assert rejected.status == 429
    assert get_resp_header(rejected, "access-control-allow-origin") == ["*"]
    assert get_resp_header(rejected, "access-control-expose-headers") == ["retry-after"]
  end
end
