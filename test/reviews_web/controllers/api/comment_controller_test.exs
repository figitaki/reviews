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

      {:ok, agent} =
        Accounts.create_agent_identity(user, %{display_name: "Codex", handle: "codex"})

      {:ok, _agent_token, agent_raw} =
        Accounts.mint_token(user, %{name: "agent", identity_id: agent.id})

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

      %{user: user, raw_token: raw, agent_raw_token: agent_raw, agent: agent, review: review}
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
    end

    test "publishes comments under the token identity", %{
      conn: conn,
      agent_raw_token: raw,
      agent: agent,
      review: review
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", %{
          "file_path" => "foo",
          "side" => "new",
          "body" => "agent pass",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
        })

      assert %{"comment_id" => _} = json_response(conn, 201)
      [thread] = ThreadsContext.list_published_threads(review.id)
      assert thread.author_id == agent.id
      assert [comment] = thread.comments
      assert comment.author_id == agent.id
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

    test "appends to an existing thread when thread_id is given", %{
      conn: conn,
      raw_token: raw,
      review: review
    } do
      first =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", %{
          "file_path" => "foo",
          "side" => "new",
          "body" => "needs a default",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
        })
        |> json_response(201)

      reply =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", %{
          "file_path" => "foo",
          "side" => "new",
          "body" => "done, defaulted to \"new\"",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1},
          "thread_id" => first["thread_id"]
        })
        |> json_response(201)

      assert reply["thread_id"] == first["thread_id"]
      refute reply["comment_id"] == first["comment_id"]

      assert [thread] = ThreadsContext.list_published_threads(review.id)
      assert length(thread.comments) == 2
    end

    test "accepts a stringified thread_id", %{conn: conn, raw_token: raw, review: review} do
      first =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", %{
          "file_path" => "foo",
          "side" => "new",
          "body" => "first",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
        })
        |> json_response(201)

      reply =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", %{
          "file_path" => "foo",
          "side" => "new",
          "body" => "second",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1},
          "thread_id" => to_string(first["thread_id"])
        })
        |> json_response(201)

      assert reply["thread_id"] == first["thread_id"]
    end

    test "a thread_id from another review opens a new thread instead of leaking", %{
      conn: conn,
      raw_token: raw,
      user: user,
      review: review
    } do
      {:ok, %{review: other}} =
        ReviewsContext.create_review_with_initial_patchset(user, %{
          title: "Other",
          description: "",
          base_sha: "cafe",
          branch_name: "carey/other",
          raw_diff: "diff --git a/bar b/bar\n--- a/bar\n+++ b/bar\n@@ -1 +1 @@\n-a\n+b\n"
        })

      {:ok, %{thread: foreign}} =
        ThreadsContext.publish_comment(other, user, %{
          "file_path" => "bar",
          "side" => "new",
          "body" => "elsewhere",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
        })

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", %{
          "file_path" => "foo",
          "side" => "new",
          "body" => "should not land on the other review",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1},
          "thread_id" => foreign.id
        })
        |> json_response(201)

      refute resp["thread_id"] == foreign.id
      assert [%{comments: [_only_one]}] = ThreadsContext.list_published_threads(other.id)
    end
  end
end
