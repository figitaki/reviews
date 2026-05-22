defmodule Reviews.Repo.Migrations.AddResolutionFieldsToThreads do
  use Ecto.Migration

  def change do
    alter table(:threads) do
      add :resolved_by_id, references(:users, on_delete: :nilify_all)
      add :resolved_at, :utc_datetime
    end

    create index(:threads, [:resolved_by_id])
  end
end
