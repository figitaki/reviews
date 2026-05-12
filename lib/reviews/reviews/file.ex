defmodule Reviews.Reviews.File do
  @moduledoc """
  Denormalized per-file row inside a patchset. Used to drive the file-tree
  sidebar without re-parsing the diff on each render.

  `status` is stored as a string ("added" | "modified" | "deleted" | "renamed")
  rather than an Ecto enum to avoid `String.to_existing_atom` churn on
  potentially user-influenced data — see Phoenix guide.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(added modified deleted renamed)

  schema "files" do
    field :path, :string
    field :old_path, :string
    field :status, :string

    belongs_to :patchset, Reviews.Reviews.Patchset

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required ~w(patchset_id path status)a
  @optional ~w(old_path)a

  def changeset(file, attrs) do
    file
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
  end

  def statuses, do: @statuses
end
