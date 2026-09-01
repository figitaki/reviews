# async: false — swaps the code-storage adapter in global application env.
defmodule Reviews.CodeStorage.SweeperTest do
  use Reviews.DataCase, async: false

  import Reviews.CodeStorageFixtures

  alias Reviews.Accounts
  alias Reviews.CodeStorage.Sweeper
  alias Reviews.Repo
  alias Reviews.Reviews.{CodeRepository, CodeSnapshot}

  setup do
    original = Application.get_env(:reviews, Reviews.CodeStorage, [])

    Application.put_env(
      :reviews,
      Reviews.CodeStorage,
      Keyword.put(original, :adapter, Reviews.CodeStorage.Stub)
    )

    on_exit(fn ->
      Application.put_env(:reviews, Reviews.CodeStorage, original)
      Application.delete_env(:reviews, Reviews.CodeStorage.Stub)
    end)

    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 8_181,
        username: "sweeper",
        email: "sweeper@example.com",
        avatar_url: nil
      })

    {:ok, identity} = Accounts.ensure_human_identity(user)
    %{identity: identity}
  end

  test "deletes expired staging repositories via the adapter", %{identity: identity} do
    past = DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)
    stale_repo = code_repository_fixture(identity, %{expires_at: past})
    stale_snap = code_snapshot_fixture(identity, stale_repo, %{expires_at: past})
    fresh_repo = code_repository_fixture(identity)

    Sweeper.sweep()

    assert Repo.get(CodeRepository, stale_repo.id) == nil
    # Snapshot rows cascade with their repository.
    assert Repo.get(CodeSnapshot, stale_snap.id) == nil
    assert Repo.get(CodeRepository, fresh_repo.id)
  end

  test "records a redacted error and keeps the row when provider deletion fails", %{
    identity: identity
  } do
    Application.put_env(:reviews, Reviews.CodeStorage.Stub,
      delete_repository: {:error, "boom at https://api.example.code.storage/api/repos/x"}
    )

    past = DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)
    stale_repo = code_repository_fixture(identity, %{expires_at: past})

    Sweeper.sweep()

    repo = Repo.get!(CodeRepository, stale_repo.id)
    assert repo.last_error =~ "[url]"
    refute repo.last_error =~ "code.storage"
  end

  test "expires unclaimed snapshots", %{identity: identity} do
    past = DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)
    repo = code_repository_fixture(identity)
    snap = code_snapshot_fixture(identity, repo, %{expires_at: past})

    Sweeper.sweep()

    assert Repo.get!(CodeSnapshot, snap.id).status == "expired"
  end
end
