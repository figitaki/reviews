defmodule Reviews.Repo.Migrations.AddDiffPayloadToFiles do
  use Ecto.Migration

  def change do
    alter table(:files) do
      add :additions, :integer, null: false, default: 0
      add :deletions, :integer, null: false, default: 0
      add :raw_diff, :text, null: false, default: ""
    end
  end
end
