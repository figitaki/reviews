defmodule Reviews.Reviews.Patchset do
  @moduledoc """
  A single uploaded diff for a review. Patchsets are append-only and numbered
  per-review (1, 2, 3...).

  `parsed_diff` caches the `FileDiffMetadata[]` shape produced by
  `@pierre/diffs`' `parsePatchFiles` — we may pre-populate it later or leave
  it to the client to parse. For Stream 1 we just persist `raw_diff`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "patchsets" do
    field :number, :integer
    field :raw_diff, :string
    field :parsed_diff, :map
    field :base_sha, :string
    field :branch_name, :string
    field :pushed_at, :utc_datetime

    belongs_to :review, Reviews.Reviews.Review
    has_many :files, Reviews.Reviews.File

    timestamps(type: :utc_datetime)
  end

  @required ~w(review_id number raw_diff)a
  @optional ~w(parsed_diff base_sha branch_name pushed_at)a

  def changeset(patchset, attrs) do
    patchset
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:review_id, :number])
  end
end
