defmodule Reviews.Repo.Migrations.AddPreferencesToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :preferences, :map, null: false, default: %{}
    end
  end
end
