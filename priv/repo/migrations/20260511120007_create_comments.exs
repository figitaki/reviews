defmodule Reviews.Repo.Migrations.CreateComments do
  use Ecto.Migration

  def change do
    create table(:comments) do
      add :thread_id, references(:threads, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :restrict), null: false
      add :body, :text, null: false
      add :state, :string, null: false, default: "draft"
      add :published_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:comments, [:thread_id])
    create index(:comments, [:author_id])

    # Enforce "one in-flight draft per user per thread" per the plan.
    create unique_index(:comments, [:thread_id, :author_id],
             where: "state = 'draft'",
             name: :comments_one_draft_per_user_per_thread
           )
  end
end
