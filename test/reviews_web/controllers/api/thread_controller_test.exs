defmodule ReviewsWeb.Api.ThreadControllerTest do
  use ReviewsWeb.ConnCase, async: true

  alias Reviews.Accounts
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads

  describe "PATCH /api/v1/reviews/:slug/threads/:thread_id" do
    setup do
      {:ok, user} =
        Accounts.upsert_from_github(%{
          github_id: 109_001 + System.unique_integer([:positive]),
          username: "carey",
          email: "carey@example.com",
          avatar_url: nil
        })

      {:ok, agent} =
        Accounts.create_agent_identity(user, %{handle: "codex", display_name: "Codex"})

      {:ok, _token, raw} =
        Accounts.mint_token(user, %{"name" => "test", "identity_id" => agent.id})

      diff =
        "diff --git a/foo b/foo\n" <>
          "--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"

      {:ok, %{review: review}} =
        ReviewsContext.create_review_with_initial_patchset(user, %{
          title: "Add env",
          description: "",
          base_sha: "deadbeef",
          branch_name: "carey/env",
          raw_diff: diff
        })

      {:ok, %{thread: thread}} =
        Threads.publish_comment(review, user, %{
          "file_path" => "foo",
          "side" => "new",
          "body" => "looks good",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
        })

      %{agent: agent, raw_token: raw, review: review, thread: thread, user: user}
    end

    test "resolves a thread", %{conn: conn, raw_token: raw, review: review, thread: thread} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> patch(~p"/api/v1/reviews/#{review.slug}/threads/#{thread.id}", %{
          "status" => "resolved"
        })

      resp = json_response(conn, 200)
      assert resp["id"] == thread.id
      assert resp["status"] == "resolved"
      assert resp["resolved_by"]["kind"] == "agent"
      assert resp["resolved_by"]["handle"] == "codex"
      assert is_binary(resp["resolved_at"])
    end

    test "reopens a thread", %{
      conn: conn,
      raw_token: raw,
      review: review,
      thread: thread,
      agent: agent
    } do
      {:ok, _} = Threads.update_status(review, thread.id, agent, "resolved")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> patch(~p"/api/v1/reviews/#{review.slug}/threads/#{thread.id}", %{"status" => "open"})

      resp = json_response(conn, 200)
      assert resp["status"] == "open"
      assert resp["resolved_by"] == nil
      assert resp["resolved_at"] == nil
    end

    test "rejects invalid status", %{conn: conn, raw_token: raw, review: review, thread: thread} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> patch(~p"/api/v1/reviews/#{review.slug}/threads/#{thread.id}", %{
          "status" => "closed"
        })

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "status"
    end

    test "returns 404 for a thread outside the review", %{
      conn: conn,
      raw_token: raw,
      thread: thread,
      user: user
    } do
      {:ok, %{review: other_review}} =
        ReviewsContext.create_review_with_initial_patchset(user, %{
          title: "Other",
          raw_diff: "diff --git a/bar b/bar\n--- a/bar\n+++ b/bar\n@@ -1 +1 @@\n-old\n+new\n"
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> patch(~p"/api/v1/reviews/#{other_review.slug}/threads/#{thread.id}", %{
          "status" => "resolved"
        })

      assert %{"errors" => %{"detail" => "Thread not found"}} = json_response(conn, 404)
    end

    test "requires a bearer token", %{conn: conn, review: review, thread: thread} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> patch(~p"/api/v1/reviews/#{review.slug}/threads/#{thread.id}", %{
          "status" => "resolved"
        })

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end
end
