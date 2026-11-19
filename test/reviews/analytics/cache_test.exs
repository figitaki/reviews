defmodule Reviews.Analytics.CacheTest do
  use ExUnit.Case, async: true
  alias Reviews.Analytics.Cache

  setup do
    clock = :atomics.new(1, [])
    cache = start_supervised!({Cache, name: nil, clock: fn -> :atomics.get(clock, 1) end})
    %{cache: cache, clock: clock}
  end

  test "single flight, fixed cache lifetime and no stale response", %{cache: cache, clock: clock} do
    assert {:load, ticket} = Cache.reserve(cache)
    assert {:error, :unavailable} = Cache.reserve(cache)
    assert :ok = Cache.store(ticket, {:ok, %{counts: 3}}, cache)
    assert {:hit, %{counts: 3}} = Cache.reserve(cache)
    :atomics.put(clock, 1, 900_001)
    assert {:load, _} = Cache.reserve(cache)
  end

  test "rate limit also applies to cache hits", %{cache: cache, clock: clock} do
    {:load, ticket} = Cache.reserve(cache)
    Cache.store(ticket, {:ok, %{}}, cache)
    for _ <- 1..11, do: assert({:hit, %{}} = Cache.reserve(cache))
    assert {:error, :rate_limited} = Cache.reserve(cache)
    :atomics.put(clock, 1, 60_001)
    assert {:hit, %{}} = Cache.reserve(cache)
  end

  test "query failures back off and abandoned leases recover", %{cache: cache, clock: clock} do
    {:load, ticket} = Cache.reserve(cache)
    Cache.store(ticket, {:error, :unavailable}, cache)
    assert {:error, :unavailable} = Cache.reserve(cache)
    :atomics.put(clock, 1, 60_001)
    assert {:load, old} = Cache.reserve(cache)
    :atomics.put(clock, 1, 70_002)
    assert {:load, new} = Cache.reserve(cache)
    assert :ignored = Cache.store(old, {:ok, %{old: true}}, cache)
    assert :ok = Cache.store(new, {:ok, %{new: true}}, cache)
    assert {:hit, %{new: true}} = Cache.reserve(cache)
  end

  test "unauthenticated rate bucket cannot consume authenticated capacity", %{
    cache: cache,
    clock: clock
  } do
    for _ <- 1..120, do: assert(:ok = Cache.admit_rejection(cache))
    assert :limited = Cache.admit_rejection(cache)
    assert {:load, _} = Cache.reserve(cache)
    :atomics.put(clock, 1, 60_001)
    assert :ok = Cache.admit_rejection(cache)
  end
end
