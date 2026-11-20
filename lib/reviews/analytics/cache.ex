defmodule Reviews.Analytics.Cache do
  @moduledoc "One bounded aggregate entry and request bucket per application instance; no identities."
  use GenServer

  @ttl_ms 900_000
  @lease_ms 10_000
  @error_ms 60_000
  @rate_ms 60_000
  @rate_limit 12

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def admit_rejection(server \\ __MODULE__), do: GenServer.call(server, :admit_rejection)

  def reserve(server \\ __MODULE__), do: GenServer.call(server, :reserve)

  def store(ticket, result, server \\ __MODULE__),
    do: GenServer.call(server, {:store, ticket, result})

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    now = clock.()

    {:ok,
     %{
       clock: clock,
       period: now,
       requests: 0,
       rejected: 0,
       rejected_period: now,
       value: nil,
       until: now,
       ticket: nil
     }}
  end

  @impl true
  def handle_call(:admit_rejection, _from, state) do
    now = state.clock.()

    state =
      if now - state.rejected_period >= @rate_ms,
        do: %{state | rejected_period: now, rejected: 0},
        else: state

    case state.rejected do
      count when count >= 120 -> {:reply, :limited, state}
      _ -> {:reply, :ok, %{state | rejected: state.rejected + 1}}
    end
  end

  def handle_call(:reserve, _from, state) do
    now = state.clock.()

    state =
      if now - state.period >= @rate_ms, do: %{state | period: now, requests: 0}, else: state

    case state do
      %{requests: count} when count >= @rate_limit ->
        {:reply, {:error, :rate_limited}, state}

      _ ->
        reserve_at(now, %{state | requests: state.requests + 1})
    end
  end

  def handle_call({:store, ticket, result}, _from, %{ticket: ticket} = state)
      when not is_nil(ticket) do
    now = state.clock.()

    state =
      case result do
        {:ok, snapshot} -> %{state | value: snapshot, until: now + @ttl_ms, ticket: nil}
        _ -> %{state | value: nil, until: now + @error_ms, ticket: nil}
      end

    {:reply, :ok, state}
  end

  def handle_call({:store, _ticket, _result}, _from, state), do: {:reply, :ignored, state}

  defp reserve_at(now, %{until: expires, value: value} = state)
       when now < expires and not is_nil(value),
       do: {:reply, {:hit, value}, state}

  defp reserve_at(now, %{until: expires} = state) when now < expires,
    do: {:reply, {:error, :unavailable}, state}

  defp reserve_at(now, state) do
    ticket = make_ref()
    {:reply, {:load, ticket}, %{state | value: nil, ticket: ticket, until: now + @lease_ms}}
  end
end
