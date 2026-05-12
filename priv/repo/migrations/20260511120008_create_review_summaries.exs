defmodule Reviews.Repo.Migrations.CreateReviewSummaries do
  use Ecto.Migration

  def change do
    create table(:review_summaries) do
      add :review_id, references(:reviews, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :restrict), null: false
      add :round_number, :integer, null: false
      add :body, :text, null: false
      add :state, :string, null: false, default: "draft"
      add :published_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:review_summaries, [:review_id])

    create unique_index(:review_summaries, [:review_id, :author_id, :round_number],
             where: "state = 'draft'",
             name: :review_summaries_one_draft_per_user_per_round
           )
  end
end
