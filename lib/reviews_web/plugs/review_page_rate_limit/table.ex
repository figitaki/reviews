defmodule ReviewsWeb.Plugs.ReviewPageRateLimit.Table do
  @moduledoc """
  Owns the ETS table behind `ReviewsWeb.Plugs.ReviewPageRateLimit` and sweeps
  windows that have ended, once per window.
  """
  use GenServer

  alias ReviewsWeb.Plugs.ReviewPageRateLimit

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(__MODULE__, [:named_table, :public, :set, write_concurrency: true])
    schedule_sweep()
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    ReviewPageRateLimit.sweep()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, ReviewPageRateLimit.config()[:window_seconds] * 1000)
  end
end
