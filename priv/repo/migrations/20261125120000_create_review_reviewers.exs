defmodule Reviews.Repo.Migrations.CreateReviewReviewers do
  @moduledoc """
  Named reviewers of a review (#214). A reviewer is a GitHub account,
  matched on GitHub's numeric user ID, so the owner can add someone before
  they sign up to Reviews. `github_login` is the login GitHub returned when
  the reviewer was added, for display only.
  """
  use Ecto.Migration

  def change do
    create table(:review_reviewers) do
      add :review_id, references(:reviews, on_delete: :delete_all), null: false
      add :github_id, :bigint, null: false
      add :github_login, :string, null: false
      add :added_by_id, references(:identities, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:review_reviewers, [:review_id, :github_id])
    create index(:review_reviewers, [:github_id])
  end
end
