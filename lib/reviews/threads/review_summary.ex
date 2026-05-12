defmodule Reviews.Threads.ReviewSummary do
  @moduledoc """
  Optional top-level "overall review" comment, one per reviewer per round.
  Has the same `draft`/`published` lifecycle as Comment and is published
  atomically with the same batch.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @states ~w(draft published)

  schema "review_summaries" do
    field :round_number, :integer
    field :body, :string
    field :state, :string, default: "draft"
    field :published_at, :utc_datetime

    belongs_to :review, Reviews.Reviews.Review
    belongs_to :author, Reviews.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @required ~w(review_id author_id round_number body)a
  @optional ~w(state published_at)a

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:state, @states)
  end
end
