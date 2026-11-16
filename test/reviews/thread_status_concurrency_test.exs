defmodule Reviews.ThreadStatusConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Reviews.ThreadFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Reviews.Accounts.{Identity, User}
  alias Reviews.Repo
  alias Reviews.Reviews.Review
  alias Reviews.Threads
  alias Reviews.Threads.Thread

  setup do
    # Real, independent transactions are required to exercise PostgreSQL locks.
    :ok = Sandbox.checkout(Repo, sandbox: false)
    %{user: user, review: review} = fixture = thread_fixture()

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from t in Thread, where: t.review_id == ^review.id)
        Repo.delete_all(from r in Review, where: r.id == ^review.id)
        Repo.delete_all(from i in Identity, where: i.owner_user_id == ^user.id)
        Repo.delete_all(from u in User, where: u.id == ^user.id)
      end)
    end)

    Map.put(fixture, :supervisor, start_supervised!(Task.Supervisor))
  end

  describe "concurrent status transitions" do
    test "a resolve queued after a reopen keeps status and resolution metadata together",
         context do
      %{review: review, thread: thread, identity: identity, agent: agent} = context
      {:ok, _} = Threads.update_status(review, thread.id, identity, "resolved")

      {reopened, resolved} = contend_updates(context, {identity, "open"}, {agent, "resolved"})

      assert {:ok, %Thread{status: "open", resolved_by_id: nil, resolved_at: nil}} = reopened
      assert {:ok, %Thread{status: "resolved", resolved_by_id: resolver_id}} = resolved
      assert resolver_id == agent.id

      assert %Thread{status: "resolved", resolved_by_id: ^resolver_id, resolved_at: %DateTime{}} =
               Repo.get!(Thread, thread.id)
    end

    test "simultaneous resolves preserve the first resolver and broadcast only once", context do
      %{review: review, thread: thread, identity: identity, agent: agent} = context
      Phoenix.PubSub.subscribe(Reviews.PubSub, "review:#{review.slug}")

      {first, second} = contend_updates(context, {identity, "resolved"}, {agent, "resolved"})

      assert {:ok, resolved} = first
      assert {:ok, repeated} = second
      assert resolved.resolved_by_id == identity.id
      assert repeated.resolved_by_id == identity.id
      assert repeated.resolved_at == resolved.resolved_at
      assert repeated.updated_at == resolved.updated_at
      assert Repo.get!(Thread, thread.id).resolved_by_id == identity.id
      assert_receive {:thread_updated, %Thread{resolved_by_id: resolver_id}}
      assert resolver_id == identity.id
      refute_receive {:thread_updated, _}
    end
  end

  defp contend_updates(context, first, second) do
    %{supervisor: supervisor, thread: thread, review: review} = context
    parent = self()

    blocker =
      database_task(supervisor, fn ->
        Repo.transaction(fn ->
          Repo.one!(from t in Thread, where: t.id == ^thread.id, lock: "FOR UPDATE")
          send(parent, :row_locked)

          receive do
            :release -> :ok
          after
            10_000 -> raise "Timed out waiting to release thread lock"
          end
        end)
      end)

    assert_receive :row_locked, 5_000

    first_task = update_task(supervisor, review, thread, first)
    assert_receive {:backend, first_backend}, 5_000
    await_lock(first_backend)

    second_task = update_task(supervisor, review, thread, second)
    assert_receive {:backend, second_backend}, 5_000
    await_lock(second_backend)

    send(blocker.pid, :release)
    assert {:ok, :ok} = Task.await(blocker, 5_000)
    {Task.await(first_task, 5_000), Task.await(second_task, 5_000)}
  end

  defp update_task(supervisor, review, thread, {identity, status}) do
    parent = self()

    database_task(supervisor, fn ->
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      send(parent, {:backend, backend})
      Threads.update_status(review, thread.id, identity, status)
    end)
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

  defp await_lock(backend) do
    await_lock(backend, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_lock(backend, deadline) do
    case Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend]).rows do
      [[true]] ->
        :ok

      [[false]] ->
        assert System.monotonic_time(:millisecond) < deadline,
               "Status update never waited for the thread lock"

        receive do
        after
          10 -> await_lock(backend, deadline)
        end
    end
  end
end
