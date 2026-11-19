defmodule Reviews.Markdown.Cache do
  @moduledoc """
  Rendered HTML for Markdown sources, so a review page renders each comment
  and packet row once per node instead of on every load and every update.

  Keyed by the source itself, so a hit is always the same text. The table
  empties once it holds `@max_bytes` of source and HTML, and on restart, so
  a renderer change applies to everything after a deploy.
  """
  use GenServer

  @max_bytes 32 * 1024 * 1024

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The value cached for `source`, or `fun.()`, stored under it."
  def fetch(source, fun) when is_binary(source) do
    case :ets.lookup(__MODULE__, source) do
      [{^source, value}] ->
        value

      [] ->
        value = fun.()
        size = byte_size(source) + byte_size(value)

        if :ets.update_counter(__MODULE__, :bytes, size, {:bytes, 0}) > @max_bytes,
          do: :ets.delete_all_objects(__MODULE__)

        :ets.insert(__MODULE__, {source, value})
        value
    end
  end

  @impl true
  def init(nil) do
    :ets.new(__MODULE__, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    {:ok, nil}
  end
end
