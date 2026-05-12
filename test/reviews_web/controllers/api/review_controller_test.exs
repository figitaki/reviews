defmodule ReviewsWeb.Api.ReviewControllerTest do
  use ReviewsWeb.ConnCase, async: true

  alias Reviews.Accounts

  describe "POST /api/v1/reviews" do
    setup do
      {:ok, user} =
        Accounts.upsert_from_github(%{
          github_id: 12_345,
          username: "carey",
          email: "carey@example.com",
          avatar_url: nil
        })

      {:ok, _token, raw} = Accounts.mint_token(user, %{"name" => "test"})
      %{user: user, raw_token: raw}
    end

    test "creates a review + patchset with a valid token", %{conn: conn, raw_token: raw} do
      body = %{
        "title" => "Make user lookup faster",
        "description" => "A short description.",
        "base_sha" => "deadbeef",
        "branch_name" => "carey/perf",
        "raw_diff" => "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews", body)

      assert %{
               "id" => _,
               "slug" => slug,
               "url" => url,
               "patchset_number" => 1
             } = json_response(conn, 201)

      assert is_binary(slug) and slug != ""
      assert url =~ slug
    end

    test "rejects requests with no bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews", %{"title" => "x"})

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "rejects requests with a bad token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews", %{"title" => "x"})

      assert json_response(conn, 401)
    end
  end
end
