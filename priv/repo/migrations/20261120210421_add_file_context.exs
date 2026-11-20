defmodule Reviews.Repo.Migrations.AddFileContext do
  use Ecto.Migration

  def change do
    alter table(:files) do
      add :has_context, :boolean, null: false, default: false
      add :context, :map
    end
  end
end
