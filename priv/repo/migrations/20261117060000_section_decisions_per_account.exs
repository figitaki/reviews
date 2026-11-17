defmodule Reviews.Repo.Migrations.SectionDecisionsPerAccount do
  use Ecto.Migration

  # Section decisions belong to the account (a person and their agent
  # identities), not to one identity. `author_id` stays and records which
  # identity made the decision.
  def up do
    alter table(:packet_section_decisions) do
      add :account_id, references(:users, on_delete: :delete_all)
    end

    execute """
    UPDATE packet_section_decisions d
    SET account_id = i.owner_user_id
    FROM identities i
    WHERE i.id = d.author_id
    """

    # Identities of one account may have decided the same section of the same
    # patchset separately. Keep the most recent decision of each account.
    execute """
    DELETE FROM packet_section_decisions d
    USING packet_section_decisions newer
    WHERE newer.review_id = d.review_id
      AND newer.patchset_id = d.patchset_id
      AND newer.account_id = d.account_id
      AND newer.section_index = d.section_index
      AND (newer.updated_at, newer.id) > (d.updated_at, d.id)
    """

    execute "DELETE FROM packet_section_decisions WHERE account_id IS NULL"

    alter table(:packet_section_decisions) do
      modify :account_id, :bigint, null: false
    end

    drop unique_index(
           :packet_section_decisions,
           [:review_id, :patchset_id, :author_id, :section_index],
           name: :packet_section_decisions_one_per_user_section
         )

    create unique_index(
             :packet_section_decisions,
             [:review_id, :patchset_id, :account_id, :section_index],
             name: :packet_section_decisions_one_per_account_section
           )

    create index(:packet_section_decisions, [:account_id])
  end

  # Decisions merged per account in `up` are not split again.
  def down do
    drop index(:packet_section_decisions, [:account_id])

    drop unique_index(
           :packet_section_decisions,
           [:review_id, :patchset_id, :account_id, :section_index],
           name: :packet_section_decisions_one_per_account_section
         )

    create unique_index(
             :packet_section_decisions,
             [:review_id, :patchset_id, :author_id, :section_index],
             name: :packet_section_decisions_one_per_user_section
           )

    alter table(:packet_section_decisions) do
      remove :account_id
    end
  end
end
