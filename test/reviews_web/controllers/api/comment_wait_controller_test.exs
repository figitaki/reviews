defmodule ReviewsWeb.Api.CommentWaitControllerTest do
  use ReviewsWeb.ConnCase, async: true

  alias Reviews.Accounts
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads

  defp review!(user, branch) do
    {:ok, %{review: review}} =
      ReviewsContext.create_review_with_initial_patchset(user, %{
        title: "Wait",
        description: "",
        base_sha: "deadbeef",
        branch_name: branch,
        raw_diff: "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"
      })

    review
  end

  setup do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 99_101,
        username: "dana",
        email: "dana@example.com",
        avatar_url: nil
      })

    {:ok, _token, raw} = Accounts.mint_token(user, %{"name" => "test"})

    %{user: user, raw: raw, review: review!(user, "dana/wait")}
  end

  defp comment!(review, user, body) do
    {:ok, %{comment: comment}} =
      Threads.publish_comment(review, user, %{
        "file_path" => "foo",
        "side" => "new",
        "body" => body,
        "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
      })

    comment
  end

  defp wait(raw, reviews, query) do
    slugs = reviews |> List.wrap() |> Enum.map_join(",", & &1.slug)

    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> get("/api/v1/comments/wait", Map.put(query, "reviews", slugs))
  end

  # The request holds the test process, so a helper publishes once the
  # request has subscribed to the review's topic.
  defp publish_when_subscribed(review, user, waiter, body) do
    Task.async(fn ->
      await_subscriber("review:#{review.slug}", waiter)
      comment!(review, user, body)
    end)
  end

  defp await_subscriber(topic, pid) do
    if Enum.any?(Registry.lookup(Reviews.PubSub, topic), fn {sub, _} -> sub == pid end) do
      :ok
    else
      receive after: (5 -> await_subscriber(topic, pid))
    end
  end

  test "returns comments after the cursor at once", %{raw: raw, review: review, user: user} do
    first = comment!(review, user, "first")
    second = comment!(review, user, "second")

    body = wait(raw, review, %{"since" => "0", "timeout" => "30"}) |> json_response(200)

    assert Enum.map(body["comments"], & &1["comment_id"]) == [first.id, second.id]

    assert %{
             "review" => slug,
             "thread_id" => thread_id,
             "author" => "dana",
             "file_path" => "foo",
             "line" => 1,
             "body" => "first",
             "truncated" => false
           } = hd(body["comments"])

    assert slug == review.slug and thread_id == first.thread_id
    assert body["cursor"] == second.id
    refute body["more"]

    limited = wait(raw, review, %{"since" => "0", "limit" => "1"}) |> json_response(200)
    assert Enum.map(limited["comments"], & &1["comment_id"]) == [first.id]
    assert limited["cursor"] == first.id
    assert limited["more"]
  end

  test "wakes when a new comment is published", %{raw: raw, review: review, user: user} do
    old = comment!(review, user, "old")
    task = publish_when_subscribed(review, user, self(), "new")

    body = wait(raw, review, %{"timeout" => "30"}) |> json_response(200)
    new = Task.await(task)

    assert [%{"comment_id" => id, "body" => "new"}] = body["comments"]
    assert id == new.id and id > old.id
    assert body["cursor"] == new.id
  end

  test "one cursor covers several reviews", %{raw: raw, review: review, user: user} do
    other = review!(user, "dana/other")
    a = comment!(review, user, "on first")
    b = comment!(other, user, "on second")
    task = publish_when_subscribed(other, user, self(), "later")

    body =
      wait(raw, [review, other], %{"since" => "#{b.id}", "timeout" => "30"}) |> json_response(200)

    later = Task.await(task)

    assert [%{"review" => slug, "comment_id" => id}] = body["comments"]
    assert slug == other.slug and id == later.id
    assert body["cursor"] == later.id

    body = wait(raw, [review, other], %{"since" => "0", "timeout" => "0"}) |> json_response(200)

    assert Enum.map(body["comments"], &{&1["review"], &1["comment_id"]}) ==
             [{review.slug, a.id}, {other.slug, b.id}, {other.slug, later.id}]
  end

  test "caps long bodies", %{raw: raw, review: review, user: user} do
    comment!(review, user, String.duplicate("x", 9_000))
    [item] = wait(raw, review, %{"since" => "0"}) |> json_response(200) |> Map.fetch!("comments")
    assert item["truncated"]
    assert byte_size(item["body"]) <= 8_000
  end

  test "returns no comments and the same cursor on timeout", %{raw: raw, review: review} do
    body = wait(raw, review, %{"since" => "7", "timeout" => "0"}) |> json_response(200)
    assert body == %{"comments" => [], "cursor" => 7, "more" => false}
  end

  test "without since, the cursor starts at the latest comment", %{
    raw: raw,
    review: review,
    user: user
  } do
    latest = comment!(review, user, "seen")
    body = wait(raw, review, %{"timeout" => "0"}) |> json_response(200)
    assert body == %{"comments" => [], "cursor" => latest.id, "more" => false}
  end

  test "requires a token and existing reviews", %{raw: raw, review: review} do
    conn = get(build_conn(), "/api/v1/comments/wait", %{"reviews" => review.slug})
    assert json_response(conn, 401)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer not-a-token")
      |> get("/api/v1/comments/wait", %{"reviews" => review.slug})

    assert json_response(conn, 401)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get("/api/v1/comments/wait", %{"reviews" => "#{review.slug},missing", "timeout" => "0"})

    body = json_response(conn, 404)
    assert body["error_code"] == "review_not_found"
    assert body["error_detail"] =~ "missing"
  end

  test "rejects out-of-range parameters", %{raw: raw, review: review} do
    for query <- [
          %{"timeout" => "31"},
          %{"timeout" => "-1"},
          %{"since" => "abc"},
          %{"since" => "99999999999999999999"},
          %{"limit" => "0"},
          %{"limit" => "51"}
        ] do
      assert json_response(wait(raw, review, query), 400)["error_code"] == "invalid_request"
    end

    too_many = Enum.map_join(1..21, ",", &"r#{&1}")

    for slugs <- ["", ",", too_many] do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> get("/api/v1/comments/wait", %{"reviews" => slugs})

      assert json_response(conn, 400)["error_code"] == "invalid_request"
    end
  end
end
