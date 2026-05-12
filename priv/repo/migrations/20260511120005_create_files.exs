defmodule Reviews.Repo.Migrations.CreateFiles do
  use Ecto.Migration

  def change do
    create table(:files) do
      add :patchset_id, references(:patchsets, on_delete: :delete_all), null: false
      add :path, :string, null: false
      add :old_path, :string
      add :status, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:files, [:patchset_id])
    create unique_index(:files, [:patchset_id, :path])
  end
end
