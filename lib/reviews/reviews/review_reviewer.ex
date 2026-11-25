defmodule Reviews.Reviews.ReviewReviewer do
  @moduledoc """
  A named reviewer of a review: a GitHub account, matched on `github_id`.
  The account may not have signed up yet; it can decide sections once it
  has. `github_login` is for display only and never used to match.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "review_reviewers" do
    field :github_id, :integer
    field :github_login, :string

    belongs_to :review, Reviews.Reviews.Review
    belongs_to :added_by, Reviews.Accounts.Identity

    timestamps(type: :utc_datetime)
  end

  def changeset(reviewer, attrs) do
    reviewer
    |> cast(attrs, [:review_id, :github_id, :github_login, :added_by_id])
    |> validate_required([:review_id, :github_id, :github_login])
    |> unique_constraint([:review_id, :github_id])
  end
end
