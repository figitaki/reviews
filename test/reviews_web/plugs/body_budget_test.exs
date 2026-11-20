defmodule ReviewsWeb.BodyBudgetTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias ReviewsWeb.Plugs.BodyBudget

  test "counts streamed bytes despite missing, false, or oversized content-length" do
    for header <- [nil, "1", "999999"] do
      conn = conn(:post, "/")
      conn = if header, do: put_req_header(conn, "content-length", header), else: conn
      conn = %{conn | adapter: {ReviewsWeb.ChunkedBodyAdapter, {["123", "456", "7"], self()}}}
      assert {:more, "", _} = BodyBudget.read_body(conn, length: 6)
      assert_receive :body_read
    end
  end

  test "accepts an exact boundary split across chunks" do
    conn = %{
      conn(:post, "/")
      | adapter: {ReviewsWeb.ChunkedBodyAdapter, {["123", "456"], self()}}
    }

    assert {:ok, "123456", _} = BodyBudget.read_body(conn, length: 6)
  end

  test "rejects an over-limit final chunk, not just a :more result" do
    conn = %{conn(:post, "/") | adapter: {ReviewsWeb.ChunkedBodyAdapter, {["1234567"], self()}}}
    assert {:more, "", _} = BodyBudget.read_body(conn, length: 6)
  end
end
