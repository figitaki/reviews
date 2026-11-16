defmodule ReviewsWeb.AbuseHTTPTest do
  use ReviewsWeb.ConnCase, async: false
  import Reviews.AbuseFixtures

  setup do
    server = start_supervised!({Bandit, plug: ReviewsWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    Map.put(token_fixture(), :port, port)
  end

  test "missing auth returns 401 without waiting for a declared large body", %{port: port} do
    {:ok, socket} = connect(port)

    :ok =
      :gen_tcp.send(
        socket,
        "POST /api/v1/reviews HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 50000000\r\n\r\n"
      )

    assert {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    assert response =~ "401 Unauthorized"
    :gen_tcp.close(socket)
  end

  test "chunked JSON and urlencoded bodies enforce actual small-route bytes", %{
    port: port,
    raw: raw
  } do
    for type <- ["application/json", "application/x-www-form-urlencoded"] do
      {:ok, socket} = connect(port)

      headers =
        "POST /api/v1/reviews/no-such-review/comments HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer #{raw}\r\nContent-Type: #{type}\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"

      chunks = for _ <- 1..65, do: ["3e8\r\n", String.duplicate("x", 1_000), "\r\n"]
      :ok = :gen_tcp.send(socket, [headers, chunks, "0\r\n\r\n"])
      assert {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
      assert response =~ "413 Request Entity Too Large"
      :gen_tcp.close(socket)
    end
  end

  test "unsupported bodies return 415 without waiting for their content", %{port: port, raw: raw} do
    for type <- ["multipart/form-data; boundary=example", "text/plain"] do
      {:ok, socket} = connect(port)

      :ok =
        :gen_tcp.send(
          socket,
          "POST /api/v1/reviews HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer #{raw}\r\nContent-Type: #{type}\r\nContent-Length: 50000000\r\n\r\n"
        )

      assert {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
      assert response =~ "415 Unsupported Media Type"
      :gen_tcp.close(socket)
    end
  end

  defp connect(port), do: :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
end
