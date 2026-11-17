defmodule Reviews.CommentRevisionConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Reviews.ThreadFixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias Reviews.{Repo, Threads}
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Accounts.{Identity, User}
  alias Reviews.Reviews.Review
  alias Reviews.Threads.Thread

  test "an append between anchor validation and insertion cannot retarget the comment" do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    %{review: review, user: user, identity: identity} = thread_fixture()

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from t in Thread, where: t.review_id == ^review.id)
        Repo.delete_all(from r in Review, where: r.id == ^review.id)
        Repo.delete_all(from i in Identity, where: i.owner_user_id == ^user.id)
        Repo.delete_all(from u in User, where: u.id == ^user.id)
      end)
    end)

    first = ReviewsContext.latest_patchset(review)
    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    blocker =
      database_task(supervisor, fn ->
        Repo.transaction(fn ->
          Repo.query!("LOCK TABLE threads IN SHARE MODE")
          send(parent, :locked)

          receive do
            :release -> :ok
          after
            10_000 -> raise "Timed out waiting to release thread table"
          end
        end)
      end)

    assert_receive :locked, 5_000

    writer =
      database_task(supervisor, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(parent, {:backend, backend})

        Threads.start_thread(review, identity, %{
          "file_path" => "foo",
          "side" => "new",
          "body" => "Pinned",
          "revision" => 1,
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
        })
      end)

    assert_receive {:backend, backend}, 5_000
    await_lock(backend, System.monotonic_time(:millisecond) + 5_000)

    {:ok, second} =
      ReviewsContext.append_patchset(review, %{
        raw_diff: String.replace(first.raw_diff, "+new", "+later")
      })

    send(blocker.pid, :release)
    assert {:ok, :ok} = Task.await(blocker, 5_000)
    assert {:ok, %{thread: thread}} = Task.await(writer, 5_000)
    assert thread.originating_patchset_id == first.id
    assert thread.anchor["line_text"] == "new"

    assert {:ok, %{thread: latest}} =
             Threads.start_thread(review, identity, %{
               "file_path" => "foo",
               "side" => "new",
               "body" => "Latest",
               "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
             })

    assert latest.originating_patchset_id == second.id
    assert latest.anchor["line_text"] == "later"
  end

  defp database_task(supervisor, fun) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        Sandbox.checkin(Repo)
      end
    end)
  end

  defp await_lock(backend, deadline) do
    case Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend]).rows do
      [[true]] ->
        :ok

      [[false]] ->
        assert System.monotonic_time(:millisecond) < deadline, "Comment insertion never blocked"

        receive do
        after
          10 -> await_lock(backend, deadline)
        end
    end
  end
end
