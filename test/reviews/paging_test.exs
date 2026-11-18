defmodule Reviews.PagingTest do
  use ExUnit.Case, async: true

  alias Reviews.Paging

  test "page sizes accept integers and query strings within their bounds" do
    assert Paging.max_bytes(nil) == {:ok, 40_000}
    assert Paging.max_bytes("2000") == {:ok, 2_000}
    assert Paging.max_bytes(120_000) == {:ok, 120_000}
    assert Paging.max_bytes("1999") == {:error, :invalid_page_size}
    assert Paging.max_bytes(120_001) == {:error, :invalid_page_size}
    assert Paging.limit("100") == {:ok, 100}
    assert Paging.limit("0") == {:error, :invalid_page_size}
    assert Paging.limit("12abc") == {:error, :invalid_page_size}
  end

  test "a cursor decodes only in the query that encoded it" do
    scope = {:threads, 7, 2, "open", nil}
    cursor = Paging.encode(scope, {:position, 41, 3})

    assert cursor =~ ~r/\Ac41\.3\.\d+\z/
    assert Paging.decode(cursor, scope) == {:ok, {:position, 41, 3}}
    assert Paging.decode(cursor, {:threads, 7, 3, "open", nil}) == {:error, :invalid_cursor}
    assert Paging.decode("c41", scope) == {:error, :invalid_cursor}
    assert Paging.decode(41, scope) == {:error, :invalid_cursor}
  end
end
