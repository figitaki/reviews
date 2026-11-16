defmodule ReviewsWeb.BrowserSecurityTest do
  use ReviewsWeb.ConnCase, async: true

  test "browser responses restrict scripts without blocking styles and connections", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert [policy] = get_resp_header(conn, "content-security-policy")

    for directive <- [
          "base-uri 'self'",
          "frame-ancestors 'self'",
          "script-src 'self'",
          "object-src 'none'"
        ] do
      assert policy =~ directive
    end

    refute policy =~ "unsafe-inline"
    refute policy =~ "unsafe-eval"
    document = conn |> html_response(200) |> LazyHTML.from_document()

    assert [_] =
             document
             |> LazyHTML.query("head script[src='/assets/js/theme.js']:not([defer]):not([async])")
             |> LazyHTML.to_tree()

    assert [] = document |> LazyHTML.query("script:not([src])") |> LazyHTML.to_tree()
  end

  test "development websocket origins are restricted to the configured loopback port" do
    config = Config.Reader.read!("config/dev.exs", env: :dev)
    endpoint = config[:reviews][ReviewsWeb.Endpoint]
    port = endpoint[:http][:port]
    origins = endpoint[:check_origin]
    assert origins == ["http://localhost:#{port}", "http://127.0.0.1:#{port}"]

    for path <- ["/live/websocket", "/phoenix/live_reload/socket/websocket"] do
      for origin <- origins do
        conn = Plug.Test.conn(:get, path) |> put_req_header("origin", origin)

        refute Phoenix.Socket.Transport.check_origin(conn, __MODULE__, ReviewsWeb.Endpoint,
                 check_origin: origins
               ).halted
      end

      for origin <- [
            "https://attacker.example",
            "http://localhost:#{port + 1}",
            "http://localhost.attacker.example:#{port}"
          ] do
        conn = Plug.Test.conn(:get, path) |> put_req_header("origin", origin)

        checked =
          Phoenix.Socket.Transport.check_origin(conn, __MODULE__, ReviewsWeb.Endpoint,
            check_origin: origins
          )

        assert checked.halted
        assert checked.status == 403
      end
    end
  end
end
