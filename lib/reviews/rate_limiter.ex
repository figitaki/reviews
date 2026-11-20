defmodule Reviews.RateLimiter do
  @moduledoc """
  Per-instance, bounded, approximate client counters. Hash collisions share a
  budget conservatively. Restarting the supervised owner clears all counters.
  No request queues or per-client processes; contention fails closed.
  """
  use GenServer
  @buckets 16_384
  @window 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    table =
      :ets.new(__MODULE__, [
        :named_table,
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, table}
  end

  @doc "Consumes one request in a bounded bucket, or returns :limited."
  def check(
        policy,
        client,
        limit,
        table \\ __MODULE__,
        now \\ System.monotonic_time(:millisecond)
      )
      when policy in [:requests, :writes, :uploads, :sockets, :owners, :context] and
             is_integer(limit) and
             limit > 0 do
    key = {policy, :erlang.phash2(client, @buckets)}
    consume(table, key, limit, now, 8)
  rescue
    ArgumentError -> :limited
  end

  defp consume(_table, _key, _limit, _now, 0), do: :limited

  defp consume(table, key, limit, now, attempts) do
    case :ets.lookup(table, key) do
      [] ->
        case :ets.insert_new(table, {key, now + @window, 1}) do
          true -> :ok
          false -> consume(table, key, limit, now, attempts - 1)
        end

      [{^key, expires, count} = old] when expires <= now or count < limit ->
        replacement =
          if expires <= now, do: {key, now + @window, 1}, else: {key, expires, count + 1}

        case :ets.select_replace(table, [{old, [], [{:const, replacement}]}]) do
          1 -> :ok
          0 -> consume(table, key, limit, now, attempts - 1)
        end

      [_] ->
        :limited
    end
  end
end
