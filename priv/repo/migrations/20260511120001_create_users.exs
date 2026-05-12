defmodule Reviews.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :github_id, :bigint, null: false
      add :username, :string, null: false
      add :avatar_url, :string
      add :email, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:github_id])
    create index(:users, [:username])
  end
end
