defmodule Reviews.Repo.Migrations.CreateReviews do
  use Ecto.Migration

  def change do
    create table(:reviews) do
      add :slug, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :visibility, :string, null: false, default: "link"
      add :published_at, :utc_datetime
      add :author_id, references(:users, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:reviews, [:slug])
    create index(:reviews, [:author_id])
  end
end
