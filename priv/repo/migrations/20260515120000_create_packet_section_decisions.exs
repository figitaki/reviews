defmodule Reviews.Repo.Migrations.CreatePacketSectionDecisions do
  use Ecto.Migration

  def change do
    create table(:packet_section_decisions) do
      add :review_id, references(:reviews, on_delete: :delete_all), null: false
      add :patchset_id, references(:patchsets, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :delete_all), null: false
      add :section_index, :integer, null: false
      add :section_title, :string, null: false
      add :section_fingerprint, :string, null: false
      add :section_refs, {:array, :string}, null: false, default: []
      add :status, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:packet_section_decisions, [:review_id])
    create index(:packet_section_decisions, [:patchset_id])
    create index(:packet_section_decisions, [:author_id])

    create unique_index(
             :packet_section_decisions,
             [:review_id, :patchset_id, :author_id, :section_index],
             name: :packet_section_decisions_one_per_user_section
           )
  end
end
