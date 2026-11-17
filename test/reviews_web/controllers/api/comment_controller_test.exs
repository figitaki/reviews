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

    test "rejects revisions outside the database integer range", %{raw_token: raw, review: review} do
      for revision <- [2_147_483_648, 9_223_372_036_854_775_808] do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{raw}")
          |> post("/api/v1/reviews/#{review.slug}/comments", %{
            "file_path" => "foo",
            "side" => "new",
            "body" => "test",
            "revision" => revision,
            "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
          })

        assert json_response(conn, 422)["errors"]["detail"] =~ "revision"
      end

      assert ThreadsContext.list_published_threads(review.id) == []
    end

    test "omits null optional offsets before returning anchors to the browser", %{
      raw_token: raw,
      review: review
    } do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> post("/api/v1/reviews/#{review.slug}/comments", %{
          "file_path" => "foo",
          "side" => "new",
          "body" => "test",
          "thread_anchor" => %{
            "granularity" => "token_range",
            "line_number_hint" => 1,
            "selection_text" => "GITHUB_CLIENT_ID",
            "selection_offset" => nil
          }
        })

      anchor = json_response(conn, 201)["anchor"]
      refute Map.has_key?(anchor, "selection_offset")
      {:ok, snapshot} = Reviews.ReviewView.snapshot(review, nil)
      [payload] = Reviews.ReviewView.thread_payloads_for_file(snapshot, "foo")
      refute Map.has_key?(payload.anchor, "selection_offset")
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

    test "pins an older revision and accepts a location-free reply", %{
      raw_token: raw,
      review: review
    } do
      first = ReviewsContext.latest_patchset(review)

      {:ok, second} =
        ReviewsContext.append_patchset_unchecked(review, %{
          raw_diff: String.replace(first.raw_diff, "GITHUB_CLIENT_ID=", "NEW_VALUE=")
        })

      params = %{
        "file_path" => "foo",
        "body" => "old revision",
        "revision" => 1,
        "thread_anchor" => %{
          "granularity" => "line",
          "line_number_hint" => 1,
          "line_text" => "forged"
        }
      }

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", params)

      response = json_response(conn, 201)
      assert response["anchor"]["line_text"] == "GITHUB_CLIENT_ID="
      [thread] = ThreadsContext.list_published_threads(review.id)
      assert thread.originating_patchset_id == first.id

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", %{
          thread_id: thread.id,
          body: "reply",
          originating_patchset_id: second.id
        })

      assert json_response(conn, 201)["thread_id"] == thread.id
      [updated] = ThreadsContext.list_published_threads(review.id)
      assert updated.originating_patchset_id == first.id
      assert length(updated.comments) == 2
    end

    test "rejects missing lines, wrong token placement and invalid revisions without writing", %{
      raw_token: raw,
      review: review
    } do
      base = %{
        "file_path" => "foo",
        "body" => "bad anchor",
        "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
      }

      for params <- [
            Map.put(base, "revision", 999),
            Map.put(base, "file_path", "foreign"),
            Map.put(base, "thread_anchor", %{"granularity" => "line", "line_number_hint" => 50}),
            Map.put(base, "thread_anchor", %{
              "granularity" => "token_range",
              "line_number_hint" => 1,
              "selection_text" => "GITHUB",
              "selection_offset" => 2
            })
          ] do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{raw}")
          |> post(~p"/api/v1/reviews/#{review.slug}/comments", params)

        assert json_response(conn, 422)
      end

      assert ThreadsContext.list_published_threads(review.id) == []
    end

    test "foreign revision IDs and reply IDs cannot redirect writes", %{
      raw_token: raw,
      review: review,
      user: user
    } do
      original = ReviewsContext.latest_patchset(review)

      {:ok, %{review: foreign, patchset: foreign_revision}} =
        ReviewsContext.create_review_with_initial_patchset(user, %{
          title: "Foreign",
          raw_diff: original.raw_diff
        })

      params = %{
        "file_path" => "foo",
        "side" => "new",
        "body" => "Foreign",
        "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
      }

      {:ok, %{thread: thread}} = ThreadsContext.publish_comment(foreign, user, params)

      for {body, status} <- [
            {Map.put(params, "originating_patchset_id", foreign_revision.id), 422},
            {%{"thread_id" => thread.id, "body" => "Reply"}, 404}
          ] do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{raw}")
          |> post(~p"/api/v1/reviews/#{review.slug}/comments", body)

        assert json_response(conn, status)
      end

      assert ThreadsContext.list_published_threads(review.id) == []
      [unchanged] = ThreadsContext.list_published_threads(foreign.id)
      assert length(unchanged.comments) == 1
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

    test "rejects a file_path over 255 characters without leaking database errors",
         %{conn: conn, raw_token: raw, review: review} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews/#{review.slug}/comments", %{
          "file_path" => String.duplicate("a", 256),
          "side" => "new",
          "body" => "x",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
        })

      assert json_response(conn, 422) == %{
               "errors" => %{"detail" => "file_path should be at most 255 character(s)"}
             }

      assert ThreadsContext.list_published_threads(review.id) == []
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

    test "returns 404 for a thread_id from another review", %{
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

      assert_thread_not_found(conn, raw, review, foreign.id)
      assert [%{comments: [_only_one]}] = ThreadsContext.list_published_threads(other.id)
    end

    test "returns 404 for a thread_id that does not exist", %{
      conn: conn,
      raw_token: raw,
      review: review
    } do
      assert_thread_not_found(conn, raw, review, 2_147_483_647)
    end

    test "returns 404 for a thread_id past the bigint range", %{
      conn: conn,
      raw_token: raw,
      review: review
    } do
      assert_thread_not_found(conn, raw, review, 9_223_372_036_854_775_808)
      assert_thread_not_found(build_conn(), raw, review, "9223372036854775808")
    end

    test "returns 404 for a negative or zero thread_id", %{
      conn: conn,
      raw_token: raw,
      review: review
    } do
      assert_thread_not_found(conn, raw, review, -1)
      assert_thread_not_found(build_conn(), raw, review, 0)
      assert_thread_not_found(build_conn(), raw, review, "-7")
    end

    test "returns 404 for a thread_id that is not an integer", %{
      conn: conn,
      raw_token: raw,
      review: review
    } do
      assert_thread_not_found(conn, raw, review, "abc")
      assert_thread_not_found(build_conn(), raw, review, "7x")
      assert_thread_not_found(build_conn(), raw, review, false)
      assert_thread_not_found(build_conn(), raw, review, true)
    end
  end

  defp assert_thread_not_found(conn, raw, review, thread_id) do
    resp =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/reviews/#{review.slug}/comments", %{
        "file_path" => "foo",
        "side" => "new",
        "body" => "reply to a thread that is not here",
        "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1},
        "thread_id" => thread_id
      })
      |> json_response(404)

    assert resp == %{"errors" => %{"detail" => "Thread not found"}}
    assert ThreadsContext.list_published_threads(review.id) == []
  end
end
