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

  test "ignores forwarded headers from untrusted peers" do
    conn = conn(:get, "/") |> put_req_header("fly-client-ip", "8.8.8.8")
    assert RequestBudget.client_ip(conn, []) == conn.remote_ip
    assert RequestBudget.client_ip(conn, [conn.remote_ip]) == {8, 8, 8, 8}

    for value <- ["bad", "8.8.8.8, 1.1.1.1", ""] do
      assert RequestBudget.client_ip(put_req_header(conn, "fly-client-ip", value), [
               conn.remote_ip
             ]) == conn.remote_ip
    end

    conn = %{conn | req_headers: [{"fly-client-ip", "8.8.8.8"}, {"fly-client-ip", "1.1.1.1"}]}
    assert RequestBudget.client_ip(conn, [conn.remote_ip]) == conn.remote_ip
  end

  test "429 is cheap, retryable, and precedes authentication and parsing", %{table: table} do
    opts = [table: table, limits: [requests: 1]]

    assert RequestBudget.call(conn(:post, "/api/v1/reviews", "invalid JSON"), opts).halted ==
             false

    rejected = RequestBudget.call(conn(:post, "/api/v1/reviews", "invalid JSON"), opts)
    assert rejected.status == 429
    assert rejected.halted
    assert get_resp_header(rejected, "retry-after") == ["60"]
    assert %Plug.Conn.Unfetched{} = rejected.body_params
  end
end
