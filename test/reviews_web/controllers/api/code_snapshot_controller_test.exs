# async: false — swaps the code-storage adapter in global application env.
defmodule ReviewsWeb.Api.CodeSnapshotControllerTest do
  use ReviewsWeb.ConnCase, async: false

  import Reviews.CodeStorageFixtures

  alias Reviews.{Accounts, CodeSnapshots, Repo}
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.CodeSnapshot

  @diff "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"

  @reserve_body %{
    "object_format" => "sha1",
    "base_oid" => String.duplicate("a", 40),
    "head_oid" => String.duplicate("b", 40),
    "head_kind" => "commit"
  }

  setup do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 31_337,
        username: "snapshots",
        email: "snapshots@example.com",
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

  defp enable_stub_adapter(_ctx) do
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

    :ok
  end

  describe "with code storage disabled" do
    test "reserve returns 404 with a stable code", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/code-snapshots", @reserve_body)
      assert %{"errors" => %{"code" => "code_storage_disabled"}} = json_response(conn, 404)
    end

    test "complete returns 404 with a stable code", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/code-snapshots/#{Ecto.UUID.generate()}/complete")
      assert %{"errors" => %{"code" => "code_storage_disabled"}} = json_response(conn, 404)
    end
  end

  describe "with the stub adapter" do
    setup :enable_stub_adapter

    test "reserve creates a staging repository and returns upload instructions", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/code-snapshots", @reserve_body)
      body = json_response(conn, 201)

      assert body["id"]
      assert body["repository_id"]
      assert body["upload"]["remote_url"] == "http://stub.invalid/reviews/stub.git"
      assert body["upload"]["token"] == "stub-token"
      assert body["refs"]["base"] == "refs/heads/snapshots/#{body["id"]}/base"
      assert body["refs"]["head"] == "refs/heads/snapshots/#{body["id"]}/head"

      snapshot = CodeSnapshots.get_snapshot_by_public_id(body["id"])
      assert snapshot.status == "reserved"
      assert snapshot.code_repository.status == "staging"
      assert snapshot.code_repository.review_id == nil
    end

    test "reserve with a review slug reuses the review's claimed repository", %{
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
          CodeSnapshots.claim_for_patchset(identity, review, patchset, snap1.public_id)
        end)

      conn =
        post(conn, ~p"/api/v1/code-snapshots", Map.put(@reserve_body, "review_slug", review.slug))

      body = json_response(conn, 201)
      assert body["repository_id"] == repository.public_id
    end

    test "reserve with an unknown review slug 404s", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/code-snapshots", Map.put(@reserve_body, "review_slug", "nope1234"))

      assert json_response(conn, 404)
    end

    test "reserve rejects an unsupported object format", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/code-snapshots", Map.put(@reserve_body, "object_format", "sha256"))

      assert %{"errors" => %{"code" => "unsupported_object_format"}} = json_response(conn, 422)
    end

    test "reserve rejects malformed oids", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/code-snapshots", Map.put(@reserve_body, "base_oid", "short"))
      assert json_response(conn, 422)
    end

    test "reserve surfaces provider failure as 502", %{conn: conn} do
      Application.put_env(:reviews, Reviews.CodeStorage.Stub, create_repository: {:error, :boom})

      conn = post(conn, ~p"/api/v1/code-snapshots", @reserve_body)
      assert json_response(conn, 502)
    end

    test "complete verifies and is idempotent", %{conn: conn, identity: identity} do
      repository = code_repository_fixture(identity)
      snapshot = code_snapshot_fixture(identity, repository, %{status: "reserved"})

      conn1 = post(conn, ~p"/api/v1/code-snapshots/#{snapshot.public_id}/complete")

      assert %{"status" => "ready", "base_oid" => base} = json_response(conn1, 200)
      assert base == snapshot.base_oid

      conn2 = post(conn, ~p"/api/v1/code-snapshots/#{snapshot.public_id}/complete")
      assert %{"status" => "ready"} = json_response(conn2, 200)
    end

    test "complete marks a mismatched upload failed", %{conn: conn, identity: identity} do
      Application.put_env(:reviews, Reviews.CodeStorage.Stub, verify: {:error, :ref_mismatch})

      repository = code_repository_fixture(identity)
      snapshot = code_snapshot_fixture(identity, repository, %{status: "reserved"})

      conn = post(conn, ~p"/api/v1/code-snapshots/#{snapshot.public_id}/complete")
      assert %{"errors" => %{"code" => "ref_mismatch"}} = json_response(conn, 422)
      assert Repo.get!(CodeSnapshot, snapshot.id).status == "failed"
    end

    test "complete rejects another identity's snapshot", %{conn: conn} do
      {:ok, other_user} =
        Accounts.upsert_from_github(%{
          github_id: 41_414,
          username: "other",
          email: "other@example.com",
          avatar_url: nil
        })

      {:ok, other} = Accounts.ensure_human_identity(other_user)
      repository = code_repository_fixture(other)
      snapshot = code_snapshot_fixture(other, repository, %{status: "reserved"})

      conn = post(conn, ~p"/api/v1/code-snapshots/#{snapshot.public_id}/complete")
      assert %{"errors" => %{"code" => "snapshot_not_authorized"}} = json_response(conn, 403)
    end

    test "complete on an expired snapshot returns 410", %{conn: conn, identity: identity} do
      repository = code_repository_fixture(identity)
      snapshot = code_snapshot_fixture(identity, repository, %{status: "expired"})

      conn = post(conn, ~p"/api/v1/code-snapshots/#{snapshot.public_id}/complete")
      assert %{"errors" => %{"code" => "upload_expired"}} = json_response(conn, 410)
    end
  end

  test "reserve requires an API token" do
    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/code-snapshots", @reserve_body)

    assert json_response(conn, 401)
  end
end
