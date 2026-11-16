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

  @tag :capture_log
  test "a production canonical host does not redirect MCP requests elsewhere", ctx do
    endpoint = Application.get_env(:reviews, ReviewsWeb.Endpoint)
    on_exit(fn -> Application.put_env(:reviews, ReviewsWeb.Endpoint, endpoint) end)

    Application.put_env(
      :reviews,
      ReviewsWeb.Endpoint,
      Keyword.put(endpoint, :url, host: "reviews.example", port: 443, scheme: "https")
    )

    request = fn path ->
      %{build_conn() | host: "evil.example"}
      |> put_req_header("authorization", "Bearer " <> ctx.token)
      |> put_req_header("content-type", "application/json")
      |> post(path, JSON.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}))
    end

    # Other paths still redirect to the canonical host.
    assert request.("/api/v1/reviews").status == 301

    mcp = request.("/mcp")
    assert mcp.status == 403
    assert get_resp_header(mcp, "location") == []
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

  test "with /mcp off, the issuer offers no public clients, registration, or MCP resource" do
    Application.put_env(:reviews, :mcp, enabled: false)
    # The test resource takes public clients too; turn it off for this check.
    Application.put_env(:reviews, Reviews.OAuthTestResource, enabled: false)
    on_exit(fn -> Application.delete_env(:reviews, Reviews.OAuthTestResource) end)

    issuer = build_conn() |> get("/.well-known/oauth-authorization-server") |> json_response(200)
    assert issuer["token_endpoint_auth_methods_supported"] == ["private_key_jwt"]
    refute Map.has_key?(issuer, "registration_endpoint")
    refute "reviews:read" in issuer["scopes_supported"]

    assert build_conn() |> get("/.well-known/oauth-protected-resource/mcp") |> json_response(404)

    assert build_conn()
           |> put_req_header("content-type", "application/json")
           |> post(
             "/oauth/register",
             JSON.encode!(%{"redirect_uris" => ["https://a.example/cb"]})
           )
           |> json_response(404)
  end
end
