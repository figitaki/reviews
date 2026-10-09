defmodule Reviews.CodeSnapshotsTest do
  use Reviews.DataCase, async: true

  import Reviews.CodeStorageFixtures

  alias Reviews.{Accounts, CodeSnapshots, Repo}
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.{CodeRepository, CodeSnapshot}

  @diff "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"

  setup do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 4_242,
        username: "carey",
        email: "carey@example.com",
        avatar_url: nil
      })

    {:ok, identity} = Accounts.ensure_human_identity(user)

    {:ok, %{review: review, patchset: patchset}} =
      ReviewsContext.create_review_with_initial_patchset(identity, %{
        title: "Test review",
        raw_diff: @diff
      })

    %{identity: identity, review: review, patchset: patchset}
  end

  defp other_identity do
    {:ok, other_user} =
      Accounts.upsert_from_github(%{
        github_id: 9_999,
        username: "mallory",
        email: "mallory@example.com",
        avatar_url: nil
      })

    {:ok, other} = Accounts.ensure_human_identity(other_user)
    other
  end

  describe "claim_for_patchset/4" do
    test "claims a ready snapshot and attaches the repository to the review", ctx do
      repository = code_repository_fixture(ctx.identity)
      snapshot = code_snapshot_fixture(ctx.identity, repository)

      {:ok, claimed} =
        Repo.transaction(fn ->
          {:ok, claimed} =
            CodeSnapshots.claim_for_patchset(
              ctx.identity,
              ctx.review,
              ctx.patchset,
              snapshot.public_id
            )

          claimed
        end)

      assert claimed.status == "claimed"
      assert claimed.patchset_id == ctx.patchset.id
      assert claimed.expires_at == nil

      repository = Repo.get!(CodeRepository, repository.id)
      assert repository.review_id == ctx.review.id
      assert repository.status == "ready"
      assert repository.expires_at == nil
    end

    test "rejects a snapshot reserved by another identity", ctx do
      other = other_identity()
      repository = code_repository_fixture(other)
      snapshot = code_snapshot_fixture(other, repository)

      Repo.transaction(fn ->
        assert {:error, :snapshot_not_authorized} =
                 CodeSnapshots.claim_for_patchset(
                   ctx.identity,
                   ctx.review,
                   ctx.patchset,
                   snapshot.public_id
                 )
      end)
    end

    test "rejects unknown and malformed snapshot ids without leaking existence", ctx do
      Repo.transaction(fn ->
        assert {:error, :snapshot_not_ready} =
                 CodeSnapshots.claim_for_patchset(
                   ctx.identity,
                   ctx.review,
                   ctx.patchset,
                   Ecto.UUID.generate()
                 )

        assert {:error, :snapshot_not_ready} =
                 CodeSnapshots.claim_for_patchset(
                   ctx.identity,
                   ctx.review,
                   ctx.patchset,
                   "not-a-uuid"
                 )
      end)
    end

    test "rejects snapshots that are not ready", ctx do
      repository = code_repository_fixture(ctx.identity)

      for {status, code} <- [
            {"reserved", :snapshot_not_ready},
            {"uploading", :snapshot_not_ready},
            {"failed", :snapshot_not_ready},
            {"expired", :upload_expired}
          ] do
        snapshot = code_snapshot_fixture(ctx.identity, repository, %{status: status})

        Repo.transaction(fn ->
          assert {:error, ^code} =
                   CodeSnapshots.claim_for_patchset(
                     ctx.identity,
                     ctx.review,
                     ctx.patchset,
                     snapshot.public_id
                   )
        end)
      end
    end

    test "rejects an already-claimed snapshot", ctx do
      repository = code_repository_fixture(ctx.identity)
      snapshot = code_snapshot_fixture(ctx.identity, repository)

      Repo.transaction(fn ->
        {:ok, _} =
          CodeSnapshots.claim_for_patchset(
            ctx.identity,
            ctx.review,
            ctx.patchset,
            snapshot.public_id
          )
      end)

      {:ok, %{patchset: patchset2}} =
        ReviewsContext.append_patchset(ctx.identity, ctx.review, %{raw_diff: @diff})

      Repo.transaction(fn ->
        assert {:error, :snapshot_not_ready} =
                 CodeSnapshots.claim_for_patchset(
                   ctx.identity,
                   ctx.review,
                   patchset2,
                   snapshot.public_id
                 )
      end)
    end

    test "rejects a snapshot whose repository belongs to another review", ctx do
      {:ok, %{review: other_review}} =
        ReviewsContext.create_review_with_initial_patchset(ctx.identity, %{
          title: "Other review",
          raw_diff: @diff
        })

      repository = code_repository_fixture(ctx.identity, %{review_id: other_review.id})
      snapshot = code_snapshot_fixture(ctx.identity, repository)

      Repo.transaction(fn ->
        assert {:error, :snapshot_not_ready} =
                 CodeSnapshots.claim_for_patchset(
                   ctx.identity,
                   ctx.review,
                   ctx.patchset,
                   snapshot.public_id
                 )
      end)
    end

    test "second unclaimed repository loses the first-push race", ctx do
      repo_a = code_repository_fixture(ctx.identity)
      snap_a = code_snapshot_fixture(ctx.identity, repo_a)
      repo_b = code_repository_fixture(ctx.identity)
      snap_b = code_snapshot_fixture(ctx.identity, repo_b)

      Repo.transaction(fn ->
        {:ok, _} =
          CodeSnapshots.claim_for_patchset(
            ctx.identity,
            ctx.review,
            ctx.patchset,
            snap_a.public_id
          )
      end)

      {:ok, %{patchset: patchset2}} =
        ReviewsContext.append_patchset(ctx.identity, ctx.review, %{raw_diff: @diff})

      Repo.transaction(fn ->
        assert {:error, :snapshot_not_ready} =
                 CodeSnapshots.claim_for_patchset(
                   ctx.identity,
                   ctx.review,
                   patchset2,
                   snap_b.public_id
                 )
      end)

      assert Repo.get!(CodeRepository, repo_b.id).review_id == nil
    end

    test "a later patchset reuses the review's claimed repository with a new snapshot", ctx do
      repository = code_repository_fixture(ctx.identity)
      snap1 = code_snapshot_fixture(ctx.identity, repository)

      Repo.transaction(fn ->
        {:ok, _} =
          CodeSnapshots.claim_for_patchset(
            ctx.identity,
            ctx.review,
            ctx.patchset,
            snap1.public_id
          )
      end)

      snap2 = code_snapshot_fixture(ctx.identity, Repo.get!(CodeRepository, repository.id))

      {:ok, %{patchset: patchset2}} =
        ReviewsContext.append_patchset(ctx.identity, ctx.review, %{raw_diff: @diff})

      Repo.transaction(fn ->
        assert {:ok, claimed} =
                 CodeSnapshots.claim_for_patchset(
                   ctx.identity,
                   ctx.review,
                   patchset2,
                   snap2.public_id
                 )

        assert claimed.code_repository_id == repository.id
      end)

      # The earlier patchset's snapshot still resolves to its original refs.
      snap1 = Repo.get!(CodeSnapshot, snap1.id)
      assert snap1.status == "claimed"
      assert snap1.patchset_id == ctx.patchset.id
    end
  end

  describe "expire_stale/1" do
    test "expires unclaimed snapshots past their deadline, leaves claimed ones alone", ctx do
      repository = code_repository_fixture(ctx.identity)
      past = DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)

      stale = code_snapshot_fixture(ctx.identity, repository, %{expires_at: past})
      fresh = code_snapshot_fixture(ctx.identity, repository)
      claimed = code_snapshot_fixture(ctx.identity, repository, %{expires_at: past})

      Repo.transaction(fn ->
        {:ok, _} =
          CodeSnapshots.claim_for_patchset(
            ctx.identity,
            ctx.review,
            ctx.patchset,
            claimed.public_id
          )
      end)

      assert CodeSnapshots.expire_stale() == 1
      assert Repo.get!(CodeSnapshot, stale.id).status == "expired"
      assert Repo.get!(CodeSnapshot, fresh.id).status == "ready"
      assert Repo.get!(CodeSnapshot, claimed.id).status == "claimed"
    end
  end
end
