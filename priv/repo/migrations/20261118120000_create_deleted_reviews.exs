defmodule Reviews.Repo.Migrations.CreateDeletedReviews do
  @moduledoc """
  Slugs of hard-deleted reviews (#202), so a deleted review's link can say
  it was deleted instead of returning a generic not-found. Holds no content.
  """
  use Ecto.Migration

  def change do
    create table(:deleted_reviews) do
      add :slug, :string, null: false
      add :deleted_at, :utc_datetime, null: false
    end

    create unique_index(:deleted_reviews, [:slug])
  end
end
