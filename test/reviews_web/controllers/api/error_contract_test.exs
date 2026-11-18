defmodule ReviewsWeb.Api.ErrorContractTest do
  use ReviewsWeb.ConnCase, async: true

  test "auth and resource errors retain legacy fields with stable codes" do
    body = get(build_conn(), "/api/v1/me") |> json_response(401)

    assert body == %{
             "error_code" => "unauthorized",
             "error_detail" => "Unauthorized",
             "errors" => %{"detail" => "Unauthorized"}
           }

    body = get(build_conn(), "/api/v1/reviews/missing") |> json_response(404)
    assert body["error_code"] == "review_not_found"
    assert body["errors"]["detail"] == body["error_detail"]
  end

  test "thread and section decisions both reject missing status with 422" do
    {:ok, user} =
      Reviews.Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: "errors"
      })

    {:ok, _, raw} = Reviews.Accounts.mint_token(user, %{name: "errors"})

    for path <- [
          "/api/v1/reviews/missing/threads/1",
          "/api/v1/reviews/missing/sections/0/decision"
        ] do
      conn = build_conn() |> put_req_header("authorization", "Bearer #{raw}")

      conn =
        if String.ends_with?(path, "/decision"),
          do: post(conn, path, %{}),
          else: patch(conn, path, %{})

      body = json_response(conn, 422)
      assert body["error_code"] in ["invalid_status", "invalid_request"]
    end
  end
end
