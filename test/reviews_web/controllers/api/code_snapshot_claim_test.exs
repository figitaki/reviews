# async: false — the required-policy cases swap global code-storage config.
defmodule ReviewsWeb.Api.CodeSnapshotClaimTest do
  use ReviewsWeb.ConnCase, async: false

  import Reviews.CodeStorageFixtures

  alias Reviews.{Accounts, Repo}
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.{CodeSnapshot, Review}

  @diff "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"

  setup do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 55_555,
        username: "carey",
        email: "carey@example.com",
        avatar_url: nil
      })

    {:ok, identity} = Accounts.ensure_human_identity(user)
    {:ok, _token, raw} = Accounts.mint_token(user, %{"name" => "test"})

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")

    %{conn: conn, identity: identity}
  end

  defp set_policy(policy) do
    original = Application.get_env(:reviews, Reviews.CodeStorage, [])

    Application.put_env(
      :reviews,
      Reviews.CodeStorage,
      Keyword.put(original, :policy, policy)
    )

    on_exit(fn -> Application.put_env(:reviews, Reviews.CodeStorage, original) end)
  end

  test "review create claims a ready snapshot", %{conn: conn, identity: identity} do
    repository = code_repository_fixture(identity)
    snapshot = code_snapshot_fixture(identity, repository)

    conn =
      post(conn, ~p"/api/v1/reviews", %{
        "title" => "With code",
        "raw_diff" => @diff,
        "code_snapshot_id" => snapshot.public_id
      })

    body = json_response(conn, 201)
    assert body["code_snapshot"] == %{"id" => snapshot.public_id, "status" => "claimed"}

    assert Repo.get!(CodeSnapshot, snapshot.id).status == "claimed"
  end

  test "review create without a snapshot id omits the code_snapshot key", %{conn: conn} do
    conn = post(conn, ~p"/api/v1/reviews", %{"title" => "Plain", "raw_diff" => @diff})

    body = json_response(conn, 201)
    refute Map.has_key?(body, "code_snapshot")
  end

  test "optional policy: invalid snapshot id still creates a diff-only review", %{conn: conn} do
    conn =
      post(conn, ~p"/api/v1/reviews", %{
        "title" => "Skipped",
        "raw_diff" => @diff,
        "code_snapshot_id" => Ecto.UUID.generate()
      })

    body = json_response(conn, 201)
    assert body["code_snapshot"] == %{"status" => "skipped", "code" => "snapshot_not_ready"}
    assert Repo.get_by(Review, slug: body["slug"])
  end

  test "required policy: invalid snapshot id aborts and creates nothing", %{conn: conn} do
    set_policy(:required)
    before_count = Repo.aggregate(Review, :count)

    conn =
      post(conn, ~p"/api/v1/reviews", %{
        "title" => "Aborted",
        "raw_diff" => @diff,
        "code_snapshot_id" => Ecto.UUID.generate()
      })

    assert %{"errors" => %{"code" => "snapshot_not_ready"}} = json_response(conn, 422)
    assert Repo.aggregate(Review, :count) == before_count
  end

  test "patchset create claims a snapshot on the review's repository", %{
    conn: conn,
    identity: identity
  } do
    {:ok, %{review: review, patchset: patchset}} =
      ReviewsContext.create_review_with_initial_patchset(identity, %{
        title: "Base",
        raw_diff: @diff
      })

    repository = code_repository_fixture(identity)
    snap1 = code_snapshot_fixture(identity, repository)

    {:ok, _} =
      Repo.transaction(fn ->
        Reviews.CodeSnapshots.claim_for_patchset(identity, review, patchset, snap1.public_id)
      end)

    snap2 = code_snapshot_fixture(identity, repository)

    conn =
      post(conn, ~p"/api/v1/reviews/#{review.slug}/patchsets", %{
        "raw_diff" => @diff,
        "code_snapshot_id" => snap2.public_id
      })

    body = json_response(conn, 201)
    assert body["patchset_number"] == 2
    assert body["code_snapshot"] == %{"id" => snap2.public_id, "status" => "claimed"}

    # The earlier patchset keeps its own snapshot untouched.
    assert Repo.get!(CodeSnapshot, snap1.id).patchset_id == patchset.id
  end

  test "patchset create rejects a snapshot reserved by someone else (optional -> skipped)", %{
    conn: conn,
    identity: identity
  } do
    {:ok, other_user} =
      Accounts.upsert_from_github(%{
        github_id: 66_666,
        username: "other",
        email: "other@example.com",
        avatar_url: nil
      })

    {:ok, other} = Accounts.ensure_human_identity(other_user)

    {:ok, %{review: review}} =
      ReviewsContext.create_review_with_initial_patchset(identity, %{
        title: "Base",
        raw_diff: @diff
      })

    repository = code_repository_fixture(other)
    snapshot = code_snapshot_fixture(other, repository)

    conn =
      post(conn, ~p"/api/v1/reviews/#{review.slug}/patchsets", %{
        "raw_diff" => @diff,
        "code_snapshot_id" => snapshot.public_id
      })

    body = json_response(conn, 201)

    assert body["code_snapshot"] == %{
             "status" => "skipped",
             "code" => "snapshot_not_authorized"
           }
  end

  test "claimed snapshot status appears in the public review payload", %{
    conn: conn,
    identity: identity
  } do
    repository = code_repository_fixture(identity)
    snapshot = code_snapshot_fixture(identity, repository)

    conn =
      post(conn, ~p"/api/v1/reviews", %{
        "title" => "With code",
        "raw_diff" => @diff,
        "code_snapshot_id" => snapshot.public_id
      })

    slug = json_response(conn, 201)["slug"]

    show = get(build_conn(), ~p"/api/v1/reviews/#{slug}")
    [patchset_meta] = json_response(show, 200)["patchsets"]
    assert patchset_meta["code_snapshot_status"] == "claimed"

    # Availability only — nothing credential-shaped leaks on the public read.
    refute Map.has_key?(patchset_meta, "storage_key")
    refute Map.has_key?(patchset_meta, "base_ref")
  end
end
