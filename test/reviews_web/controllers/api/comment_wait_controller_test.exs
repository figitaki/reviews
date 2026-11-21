defmodule ReviewsWeb.Api.CommentWaitControllerTest do
  use ReviewsWeb.ConnCase, async: true

  alias Reviews.Accounts
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads
  alias Reviews.Threads.WaitSlots

  defp user!(github_id, username) do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: github_id,
        username: username,
        email: "#{username}@example.com",
        avatar_url: nil
      })

    user
  end

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
    user = user!(99_101, "dana")
    reviewer = user!(99_102, "remy")
    {:ok, identity} = Accounts.ensure_human_identity(user)
    {:ok, _token, raw} = Accounts.mint_token(user, %{"name" => "test"})
    %{user: user, identity: identity, reviewer: reviewer, raw: raw, review: review!(user, "d/w")}
  end

  defp comment!(review, author, body) do
    {:ok, %{comment: comment}} =
      Threads.publish_comment(review, author, %{
        "file_path" => "foo",
        "side" => "new",
        "body" => body,
        "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
      })

    comment
  end

  defp wait(raw, reviews, query) do
    slugs = reviews |> List.wrap() |> Enum.map_join(",", & &1.slug)
    wait_slugs(raw, slugs, query)
  end

  defp wait_slugs(raw, slugs, query) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> get("/api/v1/comments/wait", Map.put(query, "reviews", slugs))
  end

  # The request runs in the test process, so `fun` runs in a task once the
  # request has subscribed to the review's topic.
  defp once_subscribed(review, fun) do
    waiter = self()

    Task.async(fn ->
      await_subscriber("review:#{review.slug}", waiter)
      fun.()
    end)
  end

  defp await_subscriber(topic, pid) do
    if subscribed?(topic, pid) do
      :ok
    else
      receive after: (5 -> await_subscriber(topic, pid))
    end
  end

  defp subscribed?(topic, pid),
    do: Enum.any?(Registry.lookup(Reviews.PubSub, topic), fn {sub, _} -> sub == pid end)

  test "returns comments after the cursor at once", %{raw: raw, review: review, reviewer: r} do
    first = comment!(review, r, "first")
    second = comment!(review, r, "second")

    body = wait(raw, review, %{"since" => "0", "timeout" => "30"}) |> json_response(200)

    assert Enum.map(body["comments"], & &1["comment_id"]) == [first.id, second.id]

    assert %{
             "review" => slug,
             "thread_id" => thread_id,
             "author" => "remy",
             "file_path" => "foo",
             "side" => "new",
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

  test "wakes when a new thread is started", %{raw: raw, review: review, reviewer: r} do
    old = comment!(review, r, "old")
    task = once_subscribed(review, fn -> comment!(review, r, "new") end)

    body = wait(raw, review, %{"timeout" => "30"}) |> json_response(200)
    new = Task.await(task)

    assert [%{"comment_id" => id, "body" => "new"}] = body["comments"]
    assert id == new.id and id > old.id
    assert body["cursor"] == new.id
  end

  test "wakes on a reply to an existing thread", %{raw: raw, review: review, reviewer: r} do
    first = comment!(review, r, "question")
    {:ok, identity} = Accounts.ensure_human_identity(r)

    task =
      once_subscribed(review, fn ->
        {:ok, %{comment: reply}} = Threads.reply(review, identity, first.thread_id, "answer")
        reply
      end)

    body = wait(raw, review, %{"since" => "#{first.id}"}) |> json_response(200)
    reply = Task.await(task)

    assert [%{"comment_id" => id, "thread_id" => thread_id}] = body["comments"]
    assert id == reply.id and thread_id == first.thread_id
  end

  test "one cursor covers several reviews", %{raw: raw, review: review, user: u, reviewer: r} do
    other = review!(u, "d/other")
    a = comment!(review, r, "on first")
    b = comment!(other, r, "on second")
    task = once_subscribed(other, fn -> comment!(other, r, "later") end)

    body = wait(raw, [review, other], %{"since" => "#{b.id}"}) |> json_response(200)
    later = Task.await(task)

    assert [%{"review" => slug, "comment_id" => id}] = body["comments"]
    assert slug == other.slug and id == later.id
    assert body["cursor"] == later.id

    body = wait(raw, [review, other], %{"since" => "0", "timeout" => "0"}) |> json_response(200)

    assert Enum.map(body["comments"], &{&1["review"], &1["comment_id"]}) ==
             [{review.slug, a.id}, {other.slug, b.id}, {other.slug, later.id}]
  end

  test "leaves out the caller's own comments but moves the cursor past them", %{
    raw: raw,
    review: review,
    user: user,
    reviewer: r
  } do
    theirs = comment!(review, r, "theirs")
    mine = comment!(review, user, "mine")

    body = wait(raw, review, %{"since" => "0", "timeout" => "0"}) |> json_response(200)
    assert Enum.map(body["comments"], & &1["comment_id"]) == [theirs.id]
    assert body["cursor"] == mine.id
  end

  test "a cursor above every comment starts from the newest one", %{
    raw: raw,
    review: review,
    reviewer: r
  } do
    newest = comment!(review, r, "seen")
    huge = "9223372036854775807"

    body = wait(raw, review, %{"since" => huge, "timeout" => "0"}) |> json_response(200)
    assert body == %{"comments" => [], "cursor" => newest.id, "more" => false}

    task = once_subscribed(review, fn -> comment!(review, r, "next") end)
    body = wait(raw, review, %{"since" => huge}) |> json_response(200)
    assert [%{"comment_id" => id}] = body["comments"]
    assert id == Task.await(task).id
  end

  test "broadcasts it would not return cost no query", %{
    raw: raw,
    review: review,
    user: u,
    reviewer: r
  } do
    seen = comment!(review, r, "seen")
    other = review!(u, "d/elsewhere")

    stale =
      Reviews.Repo.preload(
        Threads.get_review_thread(review, seen.thread_id) |> elem(1),
        :comments
      )

    elsewhere = %{stale | review_id: other.id, comments: [%{seen | id: seen.id + 1_000}]}
    waiter = self()
    handler = "count-comment-reads-#{inspect(waiter)}"

    :telemetry.attach(
      handler,
      [:reviews, :repo, :query],
      fn _event, _measure, meta, _ ->
        if self() == waiter and meta.source == "comments", do: send(waiter, :comment_read)
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    task =
      once_subscribed(review, fn ->
        for thread <- [stale, elsewhere, stale] do
          Phoenix.PubSub.broadcast(
            Reviews.PubSub,
            "review:#{review.slug}",
            {:thread_published, thread}
          )
        end

        comment!(review, r, "new")
      end)

    body = wait(raw, review, %{"since" => "#{seen.id}"}) |> json_response(200)
    new = Task.await(task)
    assert [%{"comment_id" => id}] = body["comments"]
    assert id == new.id

    # The newest-id read and the list read, once before waiting and once on the wake.
    reads = for _ <- 1..10, do: receive(do: (:comment_read -> 1), after: (0 -> 0))
    assert Enum.sum(reads) == 4
  end

  test "returns early when a review is deleted", %{raw: raw, review: review, identity: id} do
    task = once_subscribed(review, fn -> ReviewsContext.delete_review(review, id) end)
    started = System.monotonic_time(:millisecond)

    body = wait(raw, review, %{"since" => "0"}) |> json_response(200)
    assert {:ok, _} = Task.await(task)
    assert body["comments"] == []
    assert System.monotonic_time(:millisecond) - started < 5_000
  end

  test "unsubscribes, frees its slot and leaves no broadcast in the mailbox", %{
    raw: raw,
    review: review,
    reviewer: r,
    identity: identity
  } do
    task = once_subscribed(review, fn -> comment!(review, r, "wake") end)
    wait(raw, review, %{}) |> json_response(200)
    Task.await(task)

    refute subscribed?("review:#{review.slug}", self())
    refute_received {:thread_published, _}
    slots = Registry.lookup(Reviews.Threads.WaitRegistry, identity.owner_user_id)
    refute Enum.any?(slots, fn {pid, _} -> pid == self() end)
  end

  test "returns no comments and the newest cursor on timeout", %{raw: raw, review: review} do
    body = wait(raw, review, %{"since" => "7", "timeout" => "0"}) |> json_response(200)
    assert body == %{"comments" => [], "cursor" => 0, "more" => false}
  end

  test "all identities of one account share one cap of 5 waits", %{
    raw: raw,
    review: review,
    user: user,
    reviewer: reviewer
  } do
    {:ok, agent} = Accounts.create_agent_identity(user, %{display_name: "Codex", handle: "codex"})
    {:ok, _token, agent_raw} = Accounts.mint_token(user, %{name: "agent", identity_id: agent.id})
    {:ok, _token, other_raw} = Accounts.mint_token(reviewer, %{"name" => "other"})
    test = self()

    holders =
      for _ <- 1..5 do
        spawn_link(fn ->
          :ok = WaitSlots.acquire(user.id)
          send(test, :held)
          receive do: (:stop -> :ok)
        end)
      end

    for _ <- holders, do: assert_receive(:held)

    for token <- [raw, agent_raw] do
      conn = wait(token, review, %{"timeout" => "0"})
      assert json_response(conn, 429)["error_code"] == "rate_limited"
    end

    assert json_response(wait(other_raw, review, %{"timeout" => "0"}), 200)

    for pid <- holders, do: send(pid, :stop)
  end

  test "requires a token and existing reviews", %{raw: raw, review: review} do
    conn = get(build_conn(), "/api/v1/comments/wait", %{"reviews" => review.slug})
    assert json_response(conn, 401)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer not-a-token")
      |> get("/api/v1/comments/wait", %{"reviews" => review.slug})

    assert json_response(conn, 401)

    body = wait_slugs(raw, "#{review.slug},missing", %{"timeout" => "0"}) |> json_response(404)
    assert body["error_code"] == "review_not_found"
    assert body["error_detail"] =~ "missing"
  end

  test "rejects out-of-range parameters and malformed slugs", %{raw: raw, review: review} do
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

    for slugs <- ["", ",", too_many, "a\0b", "a b", String.duplicate("a", 65)] do
      assert json_response(wait_slugs(raw, slugs, %{}), 400)["error_code"] == "invalid_request"
    end
  end
end
