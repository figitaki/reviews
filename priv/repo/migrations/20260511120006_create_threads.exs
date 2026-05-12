defmodule Reviews.Repo.Migrations.CreateThreads do
  use Ecto.Migration

  def change do
    create table(:threads) do
      add :review_id, references(:reviews, on_delete: :delete_all), null: false
      add :originating_patchset_id, references(:patchsets, on_delete: :restrict), null: false
      add :author_id, references(:users, on_delete: :restrict), null: false
      add :file_path, :string, null: false
      add :side, :string, null: false
      add :anchor, :map, null: false
      add :status, :string, null: false, default: "open"

      timestamps(type: :utc_datetime)
    end

    create index(:threads, [:review_id])
    create index(:threads, [:originating_patchset_id])
  end
end
