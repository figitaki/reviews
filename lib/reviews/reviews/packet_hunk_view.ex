defmodule Reviews.Reviews.PacketHunkView do
  @moduledoc """
  Per-reviewer viewed state for one canonical packet/changes hunk.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "packet_hunk_views" do
    field :file_path, :string
    field :row_ref, :string
    field :hunk_fingerprint, :string
    field :hunk_index, :integer
    field :line_start, :integer
    field :line_end, :integer
    field :section_index, :integer
    field :section_title, :string

    belongs_to :review, Reviews.Reviews.Review
    belongs_to :patchset, Reviews.Reviews.Patchset
    belongs_to :author, Reviews.Accounts.Identity

    timestamps(type: :utc_datetime)
  end

  @required ~w(review_id patchset_id author_id file_path row_ref hunk_fingerprint hunk_index)a
  @optional ~w(line_start line_end section_index section_title)a

  def changeset(view, attrs) do
    view
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:hunk_index, greater_than: 0)
    |> validate_number(:line_start, greater_than: 0)
    |> validate_number(:line_end, greater_than: 0)
    |> unique_constraint([:review_id, :author_id, :file_path, :row_ref, :hunk_fingerprint],
      name: :packet_hunk_views_one_per_user_hunk
    )
  end
end
