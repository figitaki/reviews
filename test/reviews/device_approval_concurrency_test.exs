defmodule Reviews.DeviceApprovalConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Gatekeep.DeviceAuthorization
  alias Gatekeep.Storage.Ecto.DeviceCode
  alias Reviews.{Accounts, OAuth, Repo}
  alias Reviews.Accounts.{Identity, User}

  test "competing new-agent approvals persist exactly the winning identity" do
    # Independent committed connections exercise the actual PostgreSQL row lock.
    :ok = Sandbox.checkout(Repo, sandbox: false)
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 9_000_000 + unique,
        username: "device-race-#{unique}"
      })

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from i in Identity, where: i.owner_user_id == ^user.id)
        Repo.delete_all(from u in User, where: u.id == ^user.id)
      end)
    end)

    {:ok, %{"user_code" => code, "device_code" => device}} =
      DeviceAuthorization.authorize(
        OAuth.config(),
        %{
          "client_id" => "reviews-cli",
          "resource" => OAuth.CLI.id()
        },
        %{}
      )

    hash = Gatekeep.Util.hash(device)
    row = Repo.get_by!(DeviceCode, device_code_hash: hash)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from d in DeviceCode, where: d.id == ^row.id)
      end)
    end)

    supervisor = start_supervised!(Task.Supervisor)
    parent = self()

    blocker =
      database_task(supervisor, fn ->
        Repo.transaction(fn ->
          Repo.one!(from d in DeviceCode, where: d.id == ^row.id, lock: "FOR UPDATE")
          send(parent, :locked)

          receive do
            :release -> :ok
          after
            10_000 -> raise "Timed out releasing the device code"
          end
        end)
      end)

    assert_receive :locked, 5_000

    writers =
      for handle <- ["first", "second"] do
        database_task(supervisor, fn ->
          %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:backend, backend})

          result =
            OAuth.approve_device_new_agent(user, code, %{
              "handle" => handle,
              "display_name" => handle
            })

          {handle, result}
        end)
      end

    # Both have passed lookup and inserted their distinct identity, and are
    # waiting at the conditional code update, before either can win.
    for _ <- writers do
      assert_receive {:backend, backend}, 5_000
      await_lock(backend, System.monotonic_time(:millisecond) + 5_000)
    end

    send(blocker.pid, :release)
    assert {:ok, :ok} = Task.await(blocker, 5_000)
    results = Enum.map(writers, &Task.await(&1, 5_000))
    assert [{winner, :ok}] = Enum.filter(results, fn {_handle, result} -> result == :ok end)

    assert [{_loser, {:error, :invalid_user_code}}] =
             Enum.reject(results, fn {_handle, result} -> result == :ok end)

    assert [identity] = Accounts.list_agent_identities_for(user)
    assert identity.handle == winner
    approved = Repo.get!(DeviceCode, row.id)
    assert approved.status == "approved"
    assert approved.subject == to_string(identity.id)
    assert approved.owner == to_string(user.id)
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
        assert System.monotonic_time(:millisecond) < deadline, "Approval never blocked"

        receive do
        after
          10 -> await_lock(backend, deadline)
        end
    end
  end
end
