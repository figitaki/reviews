defmodule ReviewsWeb.Api.ReviewPageControllerTest do
  use ReviewsWeb.ConnCase, async: true
  alias Reviews.{Accounts, Paging, Threads}
  alias Reviews.Reviews, as: ReviewsContext

  setup do
    {:ok, owner} =
      Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: "pages"
      })

    diff =
      Enum.map_join(1..3, fn n ->
        "diff --git a/f#{n} b/f#{n}\n--- a/f#{n}\n+++ b/f#{n}\n@@ -1 +1 @@\n-old\n+new\n"
      end)

    {:ok, %{review: review}} =
      ReviewsContext.create_review_with_initial_patchset(owner, %{title: "Pages", raw_diff: diff})

    threads =
      for _ <- 1..3 do
        {:ok, %{thread: thread}} =
          Threads.publish_comment(review, owner, %{
            "file_path" => "f1",
            "side" => "new",
            "body" => String.duplicate("Ü🙂漢", 1_000),
            "thread_anchor" => %{
              "granularity" => "line",
              "line_number_hint" => 1,
              "line_text" => "new"
            }
          })

        thread
      end

    %{review: review, owner: owner, threads: threads, diff: diff}
  end

  test "file and thread pages are bounded, pinned and complete", ctx do
    for {endpoint, key} <- [{"files", "files"}, {"threads", "threads"}] do
      path = "/api/v1/reviews/#{ctx.review.slug}/#{endpoint}"
      first = get(build_conn(), path, %{limit: 1, max_bytes: 2000}) |> json_response(200)
      assert length(first[key]) == 1
      assert first["revision"] == 1
      refute JSON.encode!(first) =~ "raw_diff"
      refute JSON.encode!(first) =~ String.duplicate("Ü🙂漢", 2)
      assert get(build_conn(), path, %{cursor: first["next_cursor"]}).status == 422

      second =
        get(build_conn(), path, %{limit: 1, revision: 1, cursor: first["next_cursor"]})
        |> json_response(200)

      last =
        get(build_conn(), path, %{limit: 1, revision: 1, cursor: second["next_cursor"]})
        |> json_response(200)

      assert last["next_cursor"] == nil
      assert length(Enum.uniq(first[key] ++ second[key] ++ last[key])) == 3
    end
  end

  test "long comment chunks reconstruct UTF-8 within the requested byte budget", ctx do
    [thread | _] = ctx.threads
    path = "/api/v1/reviews/#{ctx.review.slug}/threads/#{thread.id}/comments"

    chunks =
      Stream.unfold({nil, 0}, fn
        :done ->
          nil

        {cursor, count} ->
          assert count < 100
          params = %{revision: 1, max_bytes: 2000, limit: 1}
          params = if cursor, do: Map.put(params, :cursor, cursor), else: params
          conn = get(build_conn(), path, params)
          body = json_response(conn, 200)
          assert byte_size(conn.resp_body) <= 2000
          [comment] = body["comments"]
          assert String.valid?(comment["body"])
          {comment, if(body["next_cursor"], do: {body["next_cursor"], count + 1}, else: :done)}
      end)
      |> Enum.to_list()

    assert Enum.map_join(chunks, & &1["body"]) == String.duplicate("Ü🙂漢", 1_000)
    assert List.last(chunks)["complete"]
    assert length(chunks) > 1
    id = hd(chunks)["id"]
    # Byte 1 is inside the first Ü, not a valid UTF-8 boundary.
    scope = {:rest_page, :comments, ctx.review.id, 1, to_string(thread.id)}

    for offset <- [1, 999_999_999] do
      cursor = Paging.encode(scope, {:position, id, offset})
      assert get(build_conn(), path, %{revision: 1, cursor: cursor}).status == 422
    end
  end

  test "large verification metadata leaves comment bodies readable", ctx do
    [thread | _] = ctx.threads
    [comment] = Threads.list_comment_page(thread.id, 0, 1)

    comment
    |> Ecto.Changeset.change(
      attribution: %{
        "provider" => "poppy",
        "client_id" => "https://agent.example/" <> String.duplicate("x", 130_000)
      }
    )
    |> Reviews.Repo.update!()

    body =
      get(build_conn(), "/api/v1/reviews/#{ctx.review.slug}/threads/#{thread.id}/comments", %{
        max_bytes: 120_000
      })
      |> json_response(200)

    assert [%{"metadata_truncated" => true, "complete" => true, "body" => text}] =
             body["comments"]

    assert text == comment.body
  end

  test "continuations query revision metadata without aggregating file history", ctx do
    for _ <- 1..3, do: ReviewsContext.append_patchset_unchecked(ctx.review, %{raw_diff: ctx.diff})
    [thread | _] = ctx.threads

    latest =
      get(build_conn(), "/api/v1/reviews/#{ctx.review.slug}/threads", %{limit: 1})
      |> json_response(200)

    assert latest["revision"] == 4
    assert [%{"originating_revision" => 1, "anchor_status" => "current"}] = latest["threads"]

    paths = [
      "/api/v1/reviews/#{ctx.review.slug}/files",
      "/api/v1/reviews/#{ctx.review.slug}/threads",
      "/api/v1/reviews/#{ctx.review.slug}/threads/#{thread.id}/comments"
    ]

    for path <- paths do
      first =
        get(build_conn(), path, %{revision: 1, limit: 1, max_bytes: 2000}) |> json_response(200)

      assert first["next_cursor"]
      owner = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:reviews, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner, do: send(owner, {:page_query, metadata.query})
        end,
        nil
      )

      try do
        page =
          get(build_conn(), path, %{
            revision: 1,
            limit: 1,
            max_bytes: 2000,
            cursor: first["next_cursor"]
          })
          |> json_response(200)

        assert page["revision"] == 1
      after
        :telemetry.detach(handler)
      end

      queries = drain_queries([])
      assert queries != []
      refute Enum.any?(queries, &String.contains?(String.downcase(&1), "sum("))
      revisions = Enum.filter(queries, &String.contains?(&1, "FROM \"patchsets\""))
      assert revisions != []

      assert Enum.all?(revisions, fn query ->
               not String.contains?(query, "raw_diff") and
                 (String.contains?(query, "LIMIT") or String.contains?(query, "ANY("))
             end)
    end
  end

  defp drain_queries(acc) do
    receive do
      {:page_query, query} -> drain_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "cursors reject different endpoints, reviews, revisions, filters and threads", ctx do
    base = "/api/v1/reviews/#{ctx.review.slug}"
    first = get(build_conn(), base <> "/threads", %{revision: 1, limit: 1}) |> json_response(200)
    cursor = first["next_cursor"]

    {:ok, %{review: other}} =
      ReviewsContext.create_review_with_initial_patchset(
        ctx.owner,
        %{title: "Other scope", raw_diff: ctx.diff}
      )

    {:ok, _} = ReviewsContext.append_patchset_unchecked(ctx.review, %{raw_diff: ctx.diff})

    for {path, params} <- [
          {base <> "/files", %{revision: 1}},
          {"/api/v1/reviews/#{other.slug}/threads", %{revision: 1}},
          {base <> "/threads", %{revision: 2}},
          {base <> "/threads", %{revision: 1, status: "open"}},
          {base <> "/threads", %{revision: 1, path: "f1"}}
        ] do
      assert get(build_conn(), path, Map.put(params, :cursor, cursor)).status == 422
    end

    # Budgets affect page size, not the query scope.
    assert get(build_conn(), base <> "/threads", %{
             revision: 1,
             cursor: cursor,
             limit: 2,
             max_bytes: 3000
           }).status == 200

    [thread, other_thread | _] = ctx.threads
    path = base <> "/threads/#{thread.id}/comments"
    page = get(build_conn(), path, %{revision: 1, max_bytes: 2000}) |> json_response(200)

    assert get(build_conn(), base <> "/threads/#{other_thread.id}/comments", %{
             revision: 1,
             cursor: page["next_cursor"]
           }).status == 422

    assert {:error, :invalid_cursor} =
             Paging.decode(
               page["next_cursor"],
               {:thread, ctx.review.id, 1, thread.id}
             )

    mcp_cursor = Paging.encode({:thread, ctx.review.id, 1, thread.id}, {:position, 0, 0})
    assert get(build_conn(), path, %{revision: 1, cursor: mcp_cursor}).status == 422
    scope = {:rest_page, :comments, ctx.review.id, 1, to_string(thread.id)}
    phase_cursor = Paging.encode(scope, {:fields, 0, 0})
    assert get(build_conn(), path, %{revision: 1, cursor: phase_cursor}).status == 422
  end

  test "revision validation remains independent of shared page limits", ctx do
    path = "/api/v1/reviews/#{ctx.review.slug}/files"

    for revision <- ["0", "-1", "2147483648", "999999999999999999999", "1x", "1.0", ""] do
      assert get(build_conn(), path, %{revision: revision}).status == 422
    end

    # Valid revision numbers beyond the page-size limit reach lookup, returning
    # missing rather than invalid input; the maximum never overflows PostgreSQL.
    for revision <- ["101", "2147483647"] do
      assert get(build_conn(), path, %{revision: revision}).status == 404
    end

    assert get(build_conn(), path, %{revision: "1", limit: "100", max_bytes: "120000"}).status ==
             200

    for params <- [%{limit: "101"}, %{limit: "0"}, %{max_bytes: "1999"}, %{max_bytes: "120001"}] do
      assert get(build_conn(), path, params).status == 422
    end
  end

  test "rejects malformed parameters and foreign or future threads", ctx do
    path = "/api/v1/reviews/#{ctx.review.slug}/threads"

    for params <- [
          %{limit: "0"},
          %{limit: "101"},
          %{max_bytes: "1999"},
          %{cursor: "bad"},
          %{revision: "oops"},
          %{status: "invalid"}
        ] do
      assert get(build_conn(), path, params).status == 422
    end

    assert get(build_conn(), path, %{revision: 99}).status == 404

    {:ok, %{review: other}} =
      ReviewsContext.create_review_with_initial_patchset(ctx.owner, %{
        title: "Other",
        raw_diff: ctx.diff
      })

    [thread | _] = ctx.threads

    assert get(build_conn(), "/api/v1/reviews/#{other.slug}/threads/#{thread.id}/comments").status ==
             404

    {:ok, _} = ReviewsContext.append_patchset_unchecked(ctx.review, %{raw_diff: ctx.diff})

    {:ok, %{thread: future}} =
      Threads.publish_comment(ctx.review, ctx.owner, %{
        "file_path" => "f1",
        "side" => "new",
        "body" => "later",
        "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
      })

    assert get(
             build_conn(),
             "/api/v1/reviews/#{ctx.review.slug}/threads/#{future.id}/comments",
             %{revision: 1}
           ).status == 404
  end
end
