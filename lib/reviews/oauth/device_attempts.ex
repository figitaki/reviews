defmodule Reviews.OAuth.DeviceAttempts do
  @moduledoc """
  Limits how many wrong user codes one person may enter at `/device`
  (RFC 8628 §5.1): 10 in a 15-minute window. User codes have about 34
  bits of entropy, so this keeps guessing someone else's pending sign-in out
  of reach.

  Counts live in ETS on each node; with several nodes, the limit applies per
  node, which still leaves guessing out of reach.
  """
  use GenServer

  @table __MODULE__
  @max_failures 10
  @window_seconds 15 * 60

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end

  @doc "Whether `user_id` may try another code now."
  def allowed?(user_id), do: failures(user_id) < @max_failures

  @doc "Records a wrong or expired code entered by `user_id`."
  def record_failure(user_id) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, user_id) do
      [{^user_id, count, started}] when now - started < @window_seconds ->
        :ets.insert(@table, {user_id, count + 1, started})

      _ ->
        :ets.insert(@table, {user_id, 1, now})
    end

    :ok
  end

  @doc "Forgets `user_id`'s failures. For tests."
  def reset(user_id), do: :ets.delete(@table, user_id)

  defp failures(user_id) do
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, user_id) do
      [{^user_id, count, started}] when now - started < @window_seconds -> count
      _ -> 0
    end
  end
end
