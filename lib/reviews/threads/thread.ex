defmodule Reviews.Threads.Thread do
  @moduledoc """
  An anchored discussion. `anchor` is a polymorphic jsonb discriminated by
  `granularity` ("line" or "token_range"). See the plan + `Reviews.Anchoring`
  for the dispatch logic.

  `side` is "old" or "new" (which side of the diff the comment is anchored to).
  `status` is "open" or "resolved" or "outdated".
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @sides ~w(old new)
  @statuses ~w(open resolved outdated)

  schema "threads" do
    field :file_path, :string
    field :side, :string
    field :anchor, :map
    field :status, :string, default: "open"
    field :resolved_at, :utc_datetime

    belongs_to :review, Reviews.Reviews.Review
    belongs_to :originating_patchset, Reviews.Reviews.Patchset
    belongs_to :author, Reviews.Accounts.User
    belongs_to :resolved_by, Reviews.Accounts.User
    has_many :comments, Reviews.Threads.Comment

    timestamps(type: :utc_datetime)
  end

  @required ~w(review_id originating_patchset_id file_path side anchor author_id)a
  @optional ~w(status resolved_by_id resolved_at)a

  def changeset(thread, attrs) do
    thread
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:side, @sides)
    |> validate_inclusion(:status, @statuses)
  end
end
