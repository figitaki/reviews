defmodule Reviews.Repo.Migrations.CreateCodeRepositories do
  use Ecto.Migration

  def change do
    create table(:code_repositories) do
      add :public_id, :uuid, null: false
      # Nullable while the first upload is staged; set when a patchset claims it.
      add :review_id, references(:reviews, on_delete: :nilify_all)
      add :owner_id, references(:identities, on_delete: :restrict), null: false
      add :backend, :string, null: false
      # Opaque provider locator (e.g. "reviews/<public_id>"). Never sent to the browser.
      add :storage_key, :string, null: false
      add :provider_repo_id, :string
      add :object_format, :string, null: false, default: "sha1"
      add :status, :string, null: false, default: "staging"
      add :last_error, :text
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:code_repositories, [:public_id])

    # One code repository per review once claimed.
    create unique_index(:code_repositories, [:review_id],
             where: "review_id IS NOT NULL",
             name: :code_repositories_review_id_index
           )

    create index(:code_repositories, [:status, :expires_at])
  end
end
