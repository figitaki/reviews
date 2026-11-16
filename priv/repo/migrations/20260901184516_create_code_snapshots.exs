defmodule Reviews.Repo.Migrations.CreateCodeSnapshots do
  use Ecto.Migration

  def change do
    create table(:code_snapshots) do
      add :public_id, :uuid, null: false
      add :code_repository_id, references(:code_repositories, on_delete: :delete_all), null: false

      # Nullable until a patchset claims the snapshot.
      add :patchset_id, references(:patchsets, on_delete: :nilify_all)
      add :reserved_by_id, references(:identities, on_delete: :restrict), null: false
      add :base_ref, :string, null: false
      add :head_ref, :string, null: false
      add :base_oid, :string, null: false
      add :head_oid, :string, null: false
      add :head_kind, :string, null: false
      add :status, :string, null: false, default: "reserved"
      add :last_error, :text
      # Set while unclaimed; cleared when a patchset claims the snapshot.
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:code_snapshots, [:public_id])

    # One patchset claims at most one snapshot.
    create unique_index(:code_snapshots, [:patchset_id],
             where: "patchset_id IS NOT NULL",
             name: :code_snapshots_patchset_id_index
           )

    create index(:code_snapshots, [:code_repository_id])
    create index(:code_snapshots, [:status, :expires_at])
  end
end
