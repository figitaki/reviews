defmodule Reviews.Markdown.CacheTest do
  # The cache is one named table, so this runs alone.
  use ExUnit.Case, async: false

  alias Reviews.Markdown.Cache

  @mib 1024 * 1024

  setup do
    :ets.delete_all_objects(Cache)
    :ok
  end

  # The byte count must match what the table actually holds.
  defp counted, do: Keyword.get(:ets.lookup(Cache, :bytes), :bytes, 0)

  defp held do
    for {source, value} <- :ets.tab2list(Cache), source != :bytes, reduce: 0 do
      sum -> sum + byte_size(source) + byte_size(value)
    end
  end

  test "counts the entry stored after a clear and stays under the cap" do
    for n <- 1..5 do
      source = String.duplicate(Integer.to_string(n), 10 * @mib)
      assert Cache.fetch(source, fn -> "html" end) == "html"
      assert counted() == held()
      assert held() <= 32 * @mib
    end

    # The fourth entry cleared the table, so only the fourth and fifth remain.
    assert held() == 2 * (10 * @mib + 4)
  end

  test "returns but does not store an entry larger than the cap" do
    source = String.duplicate("a", 33 * @mib)
    assert Cache.fetch(source, fn -> "html" end) == "html"
    assert :ets.lookup(Cache, source) == []
    assert counted() == 0
  end
end
