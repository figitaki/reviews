defmodule Reviews.Repo.Migrations.CreatePatchsets do
  use Ecto.Migration

  def change do
    create table(:patchsets) do
      add :review_id, references(:reviews, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :raw_diff, :text, null: false
      add :parsed_diff, :map
      add :base_sha, :string
      add :branch_name, :string
      add :pushed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:patchsets, [:review_id, :number])
  end
end
