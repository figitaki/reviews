defmodule ReviewsWeb.AbuseIntegrationTest do
  use ReviewsWeb.ConnCase, async: false
  import Reviews.AbuseFixtures
  alias ReviewsWeb.Plugs.{BodyBudget, RequireApiToken}
  alias Reviews.Accounts

  setup do
    table = :ets.new(:integration_budgets, [:set, :public])
    module = ReviewsWeb.Plugs.RequestBudget
    previous = Application.get_env(:reviews, module)
    Application.put_env(:reviews, module, table: table)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:reviews, module, previous),
        else: Application.delete_env(:reviews, module)
    end)

    Map.put(token_fixture(), :table, table)
  end

  test "missing and malformed auth rejects invalid JSON before parsing", %{conn: conn} do
    for route <- [
          "/api/v1/reviews",
          "/api/v1/reviews/demo/patchsets",
          "/api/v1/reviews/demo/comments",
          "/%61pi/v1/reviews"
        ],
        auth <- [nil, "Bearer ", "Basic bad", "Bearer rev_" <> String.duplicate("x", 32)] do
      request = put_req_header(conn, "content-type", "application/json")
      request = if auth, do: put_req_header(request, "authorization", auth), else: request
      result = post(request, route, "not json")
      assert result.status == 401
      assert %Plug.Conn.Unfetched{} = result.body_params
    end
  end

  test "full endpoint authenticates once; malformed auth never queries tokens", %{
    conn: conn,
    raw: raw
  } do
    handler = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler,
        [:reviews, :repo, :query],
        &Reviews.AbuseFixtures.observe_token_query/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    request =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{raw}")

    assert post(request, "/api/v1/reviews", review_body()).status == 201
    assert_receive :token_lookup
    refute_receive :token_lookup, 0

    malformed =
      conn
      |> put_req_header("authorization", "Basic nonsense")
      |> put_req_header("content-type", "application/json")

    assert post(malformed, "/api/v1/reviews", "not json").status == 401
    refute_receive :token_lookup, 0
  end

  test "seeded preview credentials support CLI identity and uploads", %{conn: conn} do
    for raw <- ["rev_" <> String.duplicate("a", 48), "preview-bootstrap-credential"] do
      :ok = Reviews.Release.seed_preview_token(raw)

      request =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")

      assert get(request, "/api/v1/me").status == 200
      created = post(request, "/api/v1/reviews", review_body())
      assert %{"slug" => slug} = json_response(created, 201)
      assert post(request, "/api/v1/reviews/#{slug}/patchsets", review_body()).status == 201
    end
  end

  test "assigns do not bypass auth and successful preauth is reused", %{
    conn: conn,
    user: user,
    token: token,
    raw: raw
  } do
    forged = conn |> assign(:current_user, user) |> assign(:current_identity, %{id: 123})
    assert RequireApiToken.call(forged, []).status == 401

    authenticated =
      conn |> put_req_header("authorization", "Bearer #{raw}") |> RequireApiToken.call([])

    assert :ok = Accounts.revoke_token(user, token.id)
    # Reusing the same trusted request result does not perform another lookup.
    assert RequireApiToken.call(authenticated, []).assigns.current_user.id == user.id
    fresh = conn |> put_req_header("authorization", "Bearer #{raw}") |> RequireApiToken.call([])
    assert fresh.status == 401
  end

  test "authenticated CLI review and patchset uploads exceed small budget", %{
    conn: conn,
    raw: raw
  } do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{raw}")

    created = post(conn, "/%61pi/v1/%72eviews", review_body())
    assert %{"slug" => slug} = json_response(created, 201)
    assert post(conn, "/api/v1/reviews/#{slug}/patchsets", review_body()).status == 201
    assert get(conn, "/api/v1/reviews/#{slug}").status == 200
  end

  test "small routes reject oversized JSON before decoding", %{conn: conn, raw: raw} do
    for route <- [
          "/api/v1/reviews/demo/comments",
          "/api/v1/reviews/demo/sections/0/decision",
          "/api/v1/reviews/demo/threads/1"
        ] do
      request =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{raw}")

      assert_raise Plug.Parsers.RequestTooLargeError, fn ->
        post(request, route, String.duplicate("x", 64_001))
      end
    end
  end

  test "authenticated upload accepts exactly 50MB and rejects one byte over", %{
    conn: conn,
    raw: raw
  } do
    prefix = ~s({"raw_diff":")
    body = prefix <> String.duplicate("x", 50_000_000 - byte_size(prefix) - 2) <> ~s("})
    request = Plug.Test.conn(:post, "/api/v1/reviews", body)
    request = %{request | remote_ip: conn.remote_ip}

    request =
      request
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{raw}")

    assert byte_size(BodyBudget.call(request, []).body_params["raw_diff"]) ==
             50_000_000 - byte_size(prefix) - 2

    oversized =
      Plug.Test.conn(:post, "/api/v1/reviews", body <> " ")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{raw}")

    assert_raise Plug.Parsers.RequestTooLargeError, fn -> BodyBudget.call(oversized, []) end
  end

  test "socket dispatch cannot bypass admission", %{conn: conn, table: table} do
    for _ <- 1..60, do: Reviews.RateLimiter.check(:sockets, conn.remote_ip, 60, table)
    rejected = get(conn, "/live/websocket")
    assert rejected.status == 429
  end

  test "an exhausted owner cannot evade limits with a new token or IP", %{
    conn: conn,
    user: user,
    raw: raw,
    table: table
  } do
    for _ <- 1..60, do: Reviews.RateLimiter.check(:owners, user.id, 60, table)
    {:ok, _, other_raw} = Accounts.mint_token(user, %{"name" => "second"})

    for {token, ip} <- [{raw, {192, 0, 2, 1}}, {other_raw, {192, 0, 2, 2}}] do
      result =
        %{conn | remote_ip: ip}
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{token}")
        |> post("/api/v1/reviews", "not json")

      assert result.status == 429
      assert %Plug.Conn.Unfetched{} = result.body_params
    end
  end
end
