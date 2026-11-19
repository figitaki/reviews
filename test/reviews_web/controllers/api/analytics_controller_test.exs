defmodule ReviewsWeb.Api.AnalyticsControllerTest do
  use ReviewsWeb.ConnCase, async: false
  import Reviews.AnalyticsFixtures
  import ExUnit.CaptureLog
  alias Reviews.Analytics.Credential
  @path "/api/v1/analytics/snapshot"

  setup do
    previous = Application.get_env(:reviews, :analytics_export)
    {token, config} = credential()
    Application.put_env(:reviews, :analytics_export, config)
    Supervisor.terminate_child(Reviews.Supervisor, Reviews.Analytics.Cache)
    Supervisor.restart_child(Reviews.Supervisor, Reviews.Analytics.Cache)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:reviews, :analytics_export, previous),
        else: Application.delete_env(:reviews, :analytics_export)
    end)

    %{token: token, config: config}
  end

  test "authenticated response is aggregate-only and no-store; raw credential is removed", %{
    token: token
  } do
    activity()
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(@path)
    assert %{"windows" => [_, _]} = json_response(conn, 200)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_req_header(conn, "authorization") == []
    refute conn.resp_body =~ "PRIVATE"
  end

  test "missing, malformed and user tokens cannot authenticate", %{token: token} do
    for raw <- [nil, "Bearer rev_general", "Bearer wrong", "Bearer " <> token <> "x"] do
      conn = if raw, do: put_req_header(build_conn(), "authorization", raw), else: build_conn()
      response = get(conn, @path)
      assert json_response(response, 401)["error_code"] == "unauthorized"
      assert get_resp_header(response, "cache-control") == ["no-store"]
    end
  end

  test "disabled, expired, malformed expiry, rotated and revoked credentials fail closed", %{
    token: token,
    config: config
  } do
    assert {:ok, digest} = Credential.authenticate(token)

    for replacement <- [
          [],
          Keyword.put(config, :expires_at, "invalid"),
          Keyword.put(
            config,
            :expires_at,
            DateTime.utc_now() |> DateTime.add(-1) |> DateTime.to_iso8601()
          ),
          Keyword.put(config, :token_sha256, String.duplicate("0", 64))
        ] do
      Application.put_env(:reviews, :analytics_export, replacement)
      refute Credential.current?(digest)

      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> token)
             |> get(@path)
             |> json_response(401)
    end
  end

  test "collector credential cannot authorize general APIs, public content routes or writes", %{
    token: token
  } do
    assert {:error, :invalid_token} = Reviews.Accounts.authenticate_token(token)

    # Even if it reached a context function, its principal could not write.
    {:ok, digest} = Credential.authenticate(token)
    principal = Reviews.Principal.aggregate_export(digest)

    for action <- [:comment, :push, :decide_section, {:update_thread_status, %{author_id: 1}}] do
      refute Reviews.Policy.can?(principal, action, %Reviews.Reviews.Review{})
    end

    for {method, path} <- [
          {:get, "/api/v1/me"},
          {:get, "/api/v1/reviews/anything"},
          {:post, "/api/v1/reviews"},
          {:post, "/api/v1/reviews/anything/comments"}
        ] do
      conn = build_conn() |> put_req_header("authorization", "Bearer " <> token)
      conn = dispatch(conn, @endpoint, method, path, nil)

      assert %{"error_code" => "insufficient_scope", "errors" => %{"detail" => detail}} =
               json_response(conn, 403)

      assert detail == "Credential scope denied"
    end
  end

  test "collector credential is denied by the API plug including its OAuth fallback", %{
    token: token
  } do
    conn =
      build_conn(:get, "/api/v1/me")
      |> put_req_header("authorization", "Bearer " <> token)
      |> ReviewsWeb.Plugs.RequireApiToken.call([])

    assert conn.halted
    assert json_response(conn, 401)["errors"]
    refute conn.assigns[:current_principal]
  end

  test "valid device-login CLI credentials cannot read aggregates" do
    %{user: user} = activity()
    {:ok, identity} = Reviews.Accounts.ensure_human_identity(user)

    request =
      build_conn()
      |> post("/oauth/device_authorization", %{
        "client_id" => "reviews-cli",
        "resource" => Reviews.OAuth.CLI.id()
      })
      |> json_response(200)

    assert :ok = Reviews.OAuth.approve_device(user, request["user_code"], identity.id)

    tokens =
      build_conn()
      |> post("/oauth/token", %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "client_id" => "reviews-cli",
        "device_code" => request["device_code"]
      })
      |> json_response(200)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> tokens["access_token"])
      |> get("/api/v1/me")

    assert json_response(conn, 200)["username"] == user.username

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> tokens["access_token"])
      |> get(@path)

    assert json_response(conn, 401)["errors"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "arbitrary filters, SQL, request logging params, bodies and methods are rejected before logging",
       %{token: token} do
    log =
      capture_log(fn ->
        for query <- [
              "?days=1",
              "?sql=PRIVATE-SQL",
              "?token=" <> token,
              "?request_logger=PRIVATE"
            ] do
          conn =
            build_conn()
            |> put_req_header("authorization", "Bearer " <> token)
            |> get(@path <> query)

          assert json_response(conn, 400)["error_code"] == "invalid_request"
        end

        conn =
          build_conn() |> put_req_header("authorization", "Bearer " <> token) |> post(@path, %{})

        assert json_response(conn, 405)["error_code"] == "method_not_allowed"
        assert get_resp_header(conn, "allow") == ["GET"]

        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("content-length", "100")
          |> get(@path)

        assert json_response(conn, 400)["errors"]

        # A body without Content-Length or Transfer-Encoding, as HTTP/2 allows.
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer " <> token)
          |> put_req_header("content-type", "text/plain")
          |> get(@path, "PRIVATE-BODY")

        assert get_req_header(conn, "content-length") == []
        assert json_response(conn, 400)["errors"]["detail"] == "Body is not supported"
      end)

    refute log =~ token
    refute log =~ "PRIVATE"
  end

  test "authenticated cache hits are bounded and revocation overrides the cache", %{token: token} do
    for _ <- 1..12 do
      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> token)
             |> get(@path)
             |> json_response(200)
    end

    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(@path)
    assert json_response(conn, 429)["error_code"] == "rate_limited"
    Application.delete_env(:reviews, :analytics_export)

    assert build_conn()
           |> put_req_header("authorization", "Bearer " <> token)
           |> get(@path)
           |> json_response(401)
  end

  test "a valid ordinary account token is still denied without updating its activity", %{} do
    %{user: user} = activity()
    {:ok, stored, ordinary} = Reviews.Accounts.mint_token(user)
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> ordinary) |> get(@path)
    assert json_response(conn, 401)["errors"]
    assert Reviews.Repo.get!(Reviews.Accounts.ApiToken, stored.id).last_used_at == nil
  end

  test "source failure returns a generic no-store error without query details", %{token: token} do
    {:load, ticket} = Reviews.Analytics.Cache.reserve()
    Reviews.Analytics.Cache.store(ticket, {:error, :unavailable})
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> token) |> get(@path)

    assert json_response(conn, 503) == %{
             "error_code" => "unavailable",
             "error_detail" => "Snapshot unavailable",
             "errors" => %{"detail" => "Snapshot unavailable"}
           }

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end
end
