defmodule Reviews.Threads.WaitSlotsTest do
  use ExUnit.Case, async: true

  alias Reviews.Threads.WaitSlots

  setup do
    registry = :"wait_slots_#{System.unique_integer([:positive])}"
    start_supervised!({Registry, keys: :duplicate, name: registry})
    %{registry: registry}
  end

  defp hold(identity_id, limits, registry) do
    test = self()

    pid =
      spawn_link(fn ->
        send(test, {:acquired, WaitSlots.acquire(identity_id, limits, registry)})
        receive do: (:stop -> send(test, {:released, WaitSlots.release(identity_id, registry)}))
      end)

    assert_receive {:acquired, result}
    {pid, result}
  end

  test "caps waits per identity and per node", %{registry: registry} do
    limits = %{per_identity: 2, total: 3}

    assert {_, :ok} = hold(1, limits, registry)
    assert {_, :ok} = hold(1, limits, registry)
    assert {_, {:error, :rate_limited}} = hold(1, limits, registry)
    assert {_, :ok} = hold(2, limits, registry)
    assert {_, {:error, :rate_limited}} = hold(3, limits, registry)
    assert Registry.count(registry) == 3
  end

  test "a released slot is free for the next wait", %{registry: registry} do
    limits = %{per_identity: 1, total: 10}
    {holder, :ok} = hold(7, limits, registry)
    assert {_, {:error, :rate_limited}} = hold(7, limits, registry)

    send(holder, :stop)
    assert_receive {:released, :ok}

    assert :ok = WaitSlots.acquire(7, limits, registry)
    assert :ok = WaitSlots.release(7, registry)
    assert Registry.count(registry) == 0
  end
end
