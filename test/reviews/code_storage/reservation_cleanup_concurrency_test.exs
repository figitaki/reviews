defmodule Reviews.CodeStorage.ReservationCleanupConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Reviews.CodeStorageFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Reviews.{CodeSnapshots, CodeStorage, Repo}
  alias Reviews.Accounts.{Identity, User}
  alias Reviews.CodeStorage.Sweeper
  alias Reviews.Reviews.{CodeRepository, CodeSnapshot}

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    original = Application.get_env(:reviews, CodeStorage, [])
    Application.put_env(:reviews, CodeStorage, Keyword.put(original, :adapter, CodeStorage.Stub))
    %{user: user, identity: identity} = code_storage_identity_fixture()

    on_exit(fn ->
      Application.put_env(:reviews, CodeStorage, original)
      Application.delete_env(:reviews, CodeStorage.Stub)

      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from r in CodeRepository, where: r.owner_id == ^identity.id)
        Repo.delete_all(from i in Identity, where: i.owner_user_id == ^user.id)
        Repo.delete_all(from u in User, where: u.id == ^user.id)
      end)
    end)

    %{identity: identity, supervisor: start_supervised!(Task.Supervisor)}
  end

  test "sweep skips creation in flight even after the repository deadline", context do
    {task, creator, repository_id} = pause_creation(context)
    supervisor = context.supervisor
    # Advance only the sweep's cutoff; no sleeps or real provider calls.
    cutoff = DateTime.add(DateTime.utc_now(), CodeStorage.snapshot_ttl_seconds() + 60)
    sweep = database_task(supervisor, fn -> Sweeper.sweep(cutoff) end)
    assert :ok = Task.await(sweep, 5_000)
    refute_received :provider_deleted
    assert Repo.get(CodeRepository, repository_id)
    send(creator, :finish)
    assert {:ok, %{snapshot: snapshot}} = Task.await(task, 5_000)
    assert Repo.get!(CodeSnapshot, snapshot.id).status == "reserved"
    # Once both deadlines really are stale, ordinary cleanup still works.
    Sweeper.sweep(cutoff)
    assert_received :provider_deleted
    refute Repo.get(CodeRepository, repository_id)
  end

  @tag capture_log: true
  test "a creator crash leaves a committed repository for later cleanup", context do
    {task, _creator, repository_id} = pause_creation(context)
    Task.shutdown(task, :brutal_kill)
    # Process DOWN can precede the connection finishing rollback. Taking the
    # row lock synchronizes with that rollback without sleeping.
    Repo.transaction(fn ->
      assert Repo.one(from r in CodeRepository, where: r.id == ^repository_id, lock: "FOR UPDATE")
    end)

    cutoff = DateTime.add(DateTime.utc_now(), CodeStorage.snapshot_ttl_seconds() + 60)
    Sweeper.sweep(cutoff)
    assert_received :provider_deleted
    refute Repo.get(CodeRepository, repository_id)
  end

  defp pause_creation(context) do
    %{identity: identity, supervisor: supervisor} = context
    owner = self()

    Application.put_env(:reviews, CodeStorage.Stub,
      create_repository: fn ->
        repository = Repo.one!(from r in CodeRepository, where: r.owner_id == ^identity.id)
        send(owner, {:creating, self(), repository.id})

        receive do
          :finish -> {:ok, %{provider_repo_id: "delayed-stub"}}
        after
          5_000 -> raise "test did not release creation"
        end
      end,
      delete_repository: fn ->
        send(owner, :provider_deleted)
        :ok
      end
    )

    task =
      database_task(supervisor, fn ->
        CodeSnapshots.reserve(identity, %{
          object_format: "sha1",
          base_oid: base_oid(),
          head_oid: head_oid(),
          head_kind: "commit"
        })
      end)

    assert_receive {:creating, creator, repository_id}, 5_000
    {task, creator, repository_id}
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
end
