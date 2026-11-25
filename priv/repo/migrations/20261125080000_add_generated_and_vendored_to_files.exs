defmodule Reviews.Repo.Migrations.AddGeneratedAndVendoredToFiles do
  use Ecto.Migration

  def change do
    alter table(:files) do
      add :generated, :boolean, null: false, default: false
      add :vendored, :boolean, null: false, default: false
    end
  end
end
