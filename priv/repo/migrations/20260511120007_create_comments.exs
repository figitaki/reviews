defmodule Reviews.Repo.Migrations.CreateComments do
  use Ecto.Migration

  def change do
    create table(:comments) do
      add :thread_id, references(:threads, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :restrict), null: false
      add :body, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:comments, [:thread_id])
    create index(:comments, [:author_id])
  end
end
