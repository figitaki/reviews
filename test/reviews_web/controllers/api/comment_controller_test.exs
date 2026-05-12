defmodule ReviewsWeb.Api.CommentControllerTest do
  use ReviewsWeb.ConnCase, async: true

  alias Reviews.Accounts
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads, as: ThreadsContext

  describe "POST /api/v1/reviews/:slug/comments" do
    setup do
      {:ok, user} =
        Accounts.upsert_from_github(%{
          github_id: 99_001,
          username: "carey",
          email: "carey@example.com",
          avatar_url: nil
        })

      {:ok, _token, raw} = Accounts.mint_token(user, %{"name" => "test"})

      diff =
        "diff --git a/foo b/foo\n" <>
          "--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+GITHUB_CLIENT_ID=\n"

      {:ok, %{review: review}} =
        ReviewsContext.create_review_with_initial_patchset(user, %{
          title: "Add env",
          description: "",
          base_sha: "deadbeef",
          branch_name: "carey/env",
          raw_diff: diff
        })

      %{user: user, raw_token: raw, review: review}
    end

    test "publishes a line-anchored comment", %{conn: conn, raw_token: raw, review: review} do
      body = %{
        "file_path" => "foo",
        "side" => "new",
        "body" => "looks good",
        "thread_anchor" => %{
          "granularity" => "line",
          "line_number_hint" => 1
        }
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", body)

      resp = json_response(conn, 201)
      assert is_integer(resp["thread_id"])
      assert is_integer(resp["comment_id"])
      assert resp["file_path"] == "foo"
      assert resp["side"] == "new"
      assert resp["anchor"]["granularity"] == "line"

      threads = ThreadsContext.list_published_threads(review.id)
      assert [thread] = threads
      assert thread.file_path == "foo"
      assert [comment] = thread.comments
      assert comment.body == "looks good"
      assert comment.state == "published"
    end

    test "publishes a token-range anchored comment",
         %{conn: conn, raw_token: raw, review: review} do
      body = %{
        "file_path" => "foo",
        "side" => "new",
        "body" => "rename?",
        "thread_anchor" => %{
          "granularity" => "token_range",
          "line_number_hint" => 1,
          "selection_text" => "GITHUB_CLIENT_ID",
          "selection_offset" => 0
        }
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", body)

      resp = json_response(conn, 201)
      assert resp["anchor"]["granularity"] == "token_range"
      assert resp["anchor"]["selection_text"] == "GITHUB_CLIENT_ID"
    end

    test "rejects an empty body", %{conn: conn, raw_token: raw, review: review} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", %{
          "file_path" => "foo",
          "side" => "new",
          "body" => "   ",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
        })

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "body"
    end

    test "rejects an unknown anchor granularity",
         %{conn: conn, raw_token: raw, review: review} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", %{
          "file_path" => "foo",
          "side" => "new",
          "body" => "x",
          "thread_anchor" => %{"granularity" => "block"}
        })

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "granularity"
    end

    test "returns 404 for an unknown slug", %{conn: conn, raw_token: raw} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews/missing/comments", %{
          "file_path" => "foo",
          "side" => "new",
          "body" => "x",
          "thread_anchor" => %{"granularity" => "line"}
        })

      assert %{"errors" => %{"detail" => "Review not found"}} = json_response(conn, 404)
    end

    test "requires a bearer token", %{conn: conn, review: review} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", %{"body" => "x"})

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end
end
