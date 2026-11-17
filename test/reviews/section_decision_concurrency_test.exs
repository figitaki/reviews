defmodule Reviews.SectionDecisionConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Reviews.Accounts
  alias Reviews.Accounts.{Identity, User}
  alias Reviews.PacketSectionDecisions
  alias Reviews.Repo
  alias Reviews.ReviewPacket
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.{Patchset, Review}

  setup do
    # Real, independent transactions are required to exercise PostgreSQL locks.
    :ok = Sandbox.checkout(Repo, sandbox: false)
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 2_000_000 + unique,
        username: "decider-#{unique}",
        email: "decider@example.com"
      })

    {:ok, agent} = Accounts.create_agent_identity(user, %{handle: "codex", display_name: "Codex"})

    {:ok, %{review: review, patchset: patchset}} =
      ReviewsContext.create_review_with_initial_patchset(user, %{
        title: "Decisions",
        raw_diff: "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n",
        packet: %{
          "title" => "Packet",
          "sections" => [
            %{
              "title" => "Main",
              "rows" => [%{"kind" => "hunk", "path" => "foo", "hunk_index" => 1}]
            }
          ]
        }
      })

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from r in Review, where: r.id == ^review.id)
        Repo.delete_all(from i in Identity, where: i.owner_user_id == ^user.id)
        Repo.delete_all(from u in User, where: u.id == ^user.id)
      end)
    end)

    %{
      review: review,
      patchset: patchset,
      section: ReviewPacket.section_at(patchset.packet, 0),
      human: Accounts.human_identity_for(user),
      agent: agent,
      supervisor: start_supervised!(Task.Supervisor)
    }
  end

  test "the owner's identities share one decision per section and record who made it", ctx do
    assert {:ok, %{status: "approved"} = by_agent} =
             PacketSectionDecisions.decide(
               ctx.review,
               ctx.patchset,
               ctx.agent,
               ctx.section,
               "approved"
             )

    # Setting the same status again, from either identity, changes nothing.
    assert {:ok, again} =
             PacketSectionDecisions.decide(
               ctx.review,
               ctx.patchset,
               ctx.human,
               ctx.section,
               "approved"
             )

    assert again.id == by_agent.id and again.author_id == ctx.agent.id

    assert {:ok, %{status: "denied", author_id: author_id}} =
             PacketSectionDecisions.decide(
               ctx.review,
               ctx.patchset,
               ctx.human,
               ctx.section,
               "denied"
             )

    assert author_id == ctx.human.id

    assert [%{status: "denied"}] = PacketSectionDecisions.list_for_review(ctx.review, ctx.agent)
    assert [%{status: "denied"}] = PacketSectionDecisions.list_for_review(ctx.review, ctx.human)
  end

  test "toggles queued behind a lock see each other's writes", ctx do
    parent = self()

    blocker =
      database_task(ctx.supervisor, fn ->
        Repo.transaction(fn ->
          Repo.one!(
            from p in Patchset, where: p.id == ^ctx.patchset.id, lock: "FOR NO KEY UPDATE"
          )

          send(parent, :row_locked)

          receive do
            :release -> :ok
          after
            10_000 -> raise "Timed out waiting to release the patchset lock"
          end
        end)
      end)

    assert_receive :row_locked, 5_000

    tasks =
      for identity <- [ctx.human, ctx.agent] do
        task =
          database_task(ctx.supervisor, fn ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:backend, backend})

            PacketSectionDecisions.toggle(
              ctx.review,
              ctx.patchset,
              identity,
              ctx.section,
              "approved"
            )
          end)

        assert_receive {:backend, backend}, 5_000
        await_lock(backend, System.monotonic_time(:millisecond) + 5_000)
        task
      end

    send(blocker.pid, :release)
    assert {:ok, :ok} = Task.await(blocker, 5_000)

    # The first toggle approves; the second sees that approval and clears it.
    # With stale reads, both would try to insert and one would fail.
    assert [{:ok, %{status: "approved"}}, {:ok, nil}] = Enum.map(tasks, &Task.await(&1, 5_000))
    assert [] = PacketSectionDecisions.list_for_review(ctx.review, ctx.human)
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
        if System.monotonic_time(:millisecond) > deadline, do: flunk("task never blocked")
        Process.sleep(10)
        await_lock(backend, deadline)
    end
  end
end
