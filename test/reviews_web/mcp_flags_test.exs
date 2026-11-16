defmodule ReviewsWeb.MCPFlagsTest do
  # Changes the global :mcp config, so it cannot run alongside other tests.
  use ReviewsWeb.ConnCase, async: false

  alias Reviews.Accounts
  alias Reviews.ThreadFixtures

  setup do
    previous = Application.get_env(:reviews, :mcp)
    on_exit(fn -> Application.put_env(:reviews, :mcp, previous) end)

    %{user: user, review: review, thread: thread} = ThreadFixtures.thread_fixture()
    {:ok, _token, raw} = Accounts.mint_token(user, %{"name" => "flags"})

    %{previous: previous, review: review, thread: thread, token: raw}
  end

  test "writes stay refused for clients that listed the tools before writes were turned off",
       ctx do
    Application.put_env(:reviews, :mcp, Keyword.put(ctx.previous, :writes_enabled, false))

    assert {:error, %{code: :forbidden}} =
             FastestMCP.call_tool(
               ReviewsWeb.MCP.Server,
               "reviews_update_thread_status",
               %{
                 "review" => ctx.review.slug,
                 "thread_id" => ctx.thread.id,
                 "status" => "resolved"
               },
               auth_input: %{"authorization" => "Bearer " <> ctx.token}
             )

    assert Reviews.Repo.reload!(ctx.thread).status == "open"
  end

  test "a disabled endpoint answers 404 before authentication", ctx do
    Application.put_env(:reviews, :mcp, Keyword.put(ctx.previous, :enabled, false))

    conn =
      %{build_conn() | host: "localhost"}
      |> put_req_header("authorization", "Bearer " <> ctx.token)
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}))

    assert json_response(conn, 404)
  end
end
