defmodule Reviews.CodeStorageFixtures do
  @moduledoc """
  Test helpers for seeding code repositories and snapshots directly, without
  going through the reserve API.
  """

  alias Reviews.Repo
  alias Reviews.Reviews.{CodeRepository, CodeSnapshot}

  @base_oid String.duplicate("a", 40)
  @head_oid String.duplicate("b", 40)

  def base_oid, do: @base_oid
  def head_oid, do: @head_oid

  def code_repository_fixture(identity, attrs \\ %{}) do
    public_id = Ecto.UUID.generate()

    defaults = %{
      public_id: public_id,
      backend: "code_storage",
      storage_key: "reviews/#{public_id}",
      object_format: "sha1",
      status: "staging",
      expires_at: DateTime.add(DateTime.utc_now(), 900) |> DateTime.truncate(:second)
    }

    %CodeRepository{owner_id: identity.id, review_id: attrs[:review_id]}
    |> CodeRepository.changeset(Map.merge(defaults, Map.delete(attrs, :review_id)))
    |> Repo.insert!()
  end

  def code_snapshot_fixture(identity, repository, attrs \\ %{}) do
    public_id = Ecto.UUID.generate()

    defaults = %{
      public_id: public_id,
      base_ref: "refs/heads/snapshots/#{public_id}/base",
      head_ref: "refs/heads/snapshots/#{public_id}/head",
      base_oid: @base_oid,
      head_oid: @head_oid,
      head_kind: "commit",
      status: "ready",
      expires_at: DateTime.add(DateTime.utc_now(), 900) |> DateTime.truncate(:second)
    }

    %CodeSnapshot{code_repository_id: repository.id, reserved_by_id: identity.id}
    |> CodeSnapshot.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
