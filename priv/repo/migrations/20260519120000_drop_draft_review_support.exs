defmodule Reviews.Repo.Migrations.DropDraftReviewSupport do
  use Ecto.Migration

  def change do
    drop_if_exists index(:comments, [:thread_id, :author_id],
                     name: :comments_one_draft_per_user_per_thread
                   )

    alter table(:comments) do
      remove_if_exists :state, :string
      remove_if_exists :published_at, :utc_datetime
    end

    drop_if_exists table(:review_summaries)
  end
end
