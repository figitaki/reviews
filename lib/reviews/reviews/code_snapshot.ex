defmodule Reviews.Reviews.CodeSnapshot do
  @moduledoc """
  An immutable base/head Git ref pair for one patchset.

  Snapshots move through `reserved -> uploading -> ready -> claimed`;
  failures land in `failed`, abandoned reservations in `expired`. Refs and
  OIDs are fixed at reservation time — the provider verifies that the
  uploaded refs resolve to the reserved OIDs before the snapshot becomes
  `ready`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(reserved uploading ready claimed failed expired)
  @head_kinds ~w(commit index_snapshot worktree_snapshot)
  # Full SHA-1 (40 hex) or SHA-256 (64 hex) object id.
  @oid_format ~r/^([0-9a-f]{40}|[0-9a-f]{64})$/

  schema "code_snapshots" do
    field :public_id, Ecto.UUID
    field :base_ref, :string
    field :head_ref, :string
    field :base_oid, :string
    field :head_oid, :string
    field :head_kind, :string
    field :status, :string, default: "reserved"
    field :last_error, :string
    field :expires_at, :utc_datetime

    belongs_to :code_repository, Reviews.Reviews.CodeRepository
    belongs_to :patchset, Reviews.Reviews.Patchset
    belongs_to :reserved_by, Reviews.Accounts.Identity

    timestamps(type: :utc_datetime)
  end

  @required ~w(base_ref head_ref base_oid head_oid head_kind status expires_at)a
  @optional ~w(public_id last_error)a

  @doc """
  `code_repository_id`, `patchset_id`, and `reserved_by_id` are set
  programmatically by the context, never cast from external attrs.
  """
  def changeset(code_snapshot, attrs) do
    code_snapshot
    |> cast(attrs, @required ++ @optional)
    |> put_new_public_id()
    |> validate_required([:public_id | @required])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:head_kind, @head_kinds)
    |> validate_format(:base_oid, @oid_format)
    |> validate_format(:head_oid, @oid_format)
    |> unique_constraint(:public_id)
    |> unique_constraint(:patchset_id, name: :code_snapshots_patchset_id_index)
  end

  def statuses, do: @statuses
  def head_kinds, do: @head_kinds
  def valid_oid?(oid) when is_binary(oid), do: Regex.match?(@oid_format, oid)
  def valid_oid?(_), do: false

  defp put_new_public_id(changeset) do
    case get_field(changeset, :public_id) do
      nil -> put_change(changeset, :public_id, Ecto.UUID.generate())
      _ -> changeset
    end
  end
end
