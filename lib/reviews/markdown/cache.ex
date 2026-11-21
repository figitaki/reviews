defmodule Reviews.Markdown.Cache do
  @moduledoc """
  Rendered HTML for Markdown sources, so a review page renders each comment
  and packet row once per node instead of on every load and every update.

  Keyed by the source itself, so a hit is always the same text. The table
  empties once it would hold more than `@max_bytes` of source and HTML, and
  on restart, so a renderer change applies to everything after a deploy. An
  entry larger than the cap is returned but not stored.

  Writers update the byte count without a lock. A miss that races a clear
  may insert its entry after the clear has dropped the count, so the table
  can briefly exceed the cap by the entries in flight during that clear
  (each at most `@max_bytes`); the next clear removes them.
  """
  use GenServer

  @max_bytes 32 * 1024 * 1024

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The value cached for `source`, or `fun.()`, stored under it."
  def fetch(source, fun) when is_binary(source) do
    case :ets.lookup(__MODULE__, source) do
      [{^source, value}] -> value
      [] -> store(source, fun.())
    end
  end

  defp store(source, value) do
    size = byte_size(source) + byte_size(value)

    cond do
      size > @max_bytes ->
        :ok

      :ets.update_counter(__MODULE__, :bytes, size, {:bytes, 0}) > @max_bytes ->
        # The clear drops the count too; count the entry that survives it.
        :ets.delete_all_objects(__MODULE__)
        :ets.update_counter(__MODULE__, :bytes, size, {:bytes, 0})
        :ets.insert(__MODULE__, {source, value})

      true ->
        :ets.insert(__MODULE__, {source, value})
    end

    value
  end

  @impl true
  def init(nil) do
    :ets.new(__MODULE__, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    {:ok, nil}
  end
end
