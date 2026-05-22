defmodule Reviews.Repo.Migrations.AddAgentIdentities do
  use Ecto.Migration

  def up do
    create table(:identities) do
      add :owner_user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :handle, :string, null: false
      add :display_name, :string, null: false
      add :avatar_url, :string
      add :provider, :string
      add :description, :text

      timestamps(type: :utc_datetime)
    end

    create index(:identities, [:owner_user_id])
    create unique_index(:identities, [:owner_user_id, :handle])

    create unique_index(:identities, [:owner_user_id],
             where: "kind = 'human'",
             name: :identities_one_human_per_user
           )

    execute """
    INSERT INTO identities (id, owner_user_id, kind, handle, display_name, avatar_url, provider, inserted_at, updated_at)
    SELECT id, id, 'human', username, username, avatar_url, 'GitHub', inserted_at, updated_at
    FROM users
    """

    execute """
    SELECT setval(
      pg_get_serial_sequence('identities', 'id'),
      COALESCE((SELECT MAX(id) FROM identities), 1),
      EXISTS(SELECT 1 FROM identities)
    )
    """

    retarget_author_fk(:reviews, "RESTRICT")
    retarget_author_fk(:threads, "RESTRICT")
    retarget_author_fk(:comments, "RESTRICT")
    retarget_author_fk(:packet_section_decisions, "CASCADE")
    retarget_author_fk(:packet_hunk_views, "CASCADE")

    alter table(:api_tokens) do
      add :identity_id, references(:identities, on_delete: :restrict)
    end

    execute """
    UPDATE api_tokens
    SET identity_id = identities.id
    FROM identities
    WHERE identities.owner_user_id = api_tokens.user_id
      AND identities.kind = 'human'
    """

    alter table(:api_tokens) do
      modify :identity_id, :bigint, null: false
    end

    create index(:api_tokens, [:identity_id])
  end

  def down do
    retarget_author_fk_to_users(:reviews, "RESTRICT")
    retarget_author_fk_to_users(:threads, "RESTRICT")
    retarget_author_fk_to_users(:comments, "RESTRICT")
    retarget_author_fk_to_users(:packet_section_decisions, "CASCADE")
    retarget_author_fk_to_users(:packet_hunk_views, "CASCADE")

    alter table(:api_tokens) do
      remove :identity_id
    end

    drop table(:identities)
  end

  defp retarget_author_fk(table, on_delete) do
    execute "ALTER TABLE #{table} DROP CONSTRAINT #{table}_author_id_fkey"

    execute """
    ALTER TABLE #{table}
    ADD CONSTRAINT #{table}_author_id_fkey
    FOREIGN KEY (author_id) REFERENCES identities(id) ON DELETE #{on_delete}
    """
  end

  defp retarget_author_fk_to_users(table, on_delete) do
    execute "ALTER TABLE #{table} DROP CONSTRAINT #{table}_author_id_fkey"

    execute """
    ALTER TABLE #{table}
    ADD CONSTRAINT #{table}_author_id_fkey
    FOREIGN KEY (author_id) REFERENCES users(id) ON DELETE #{on_delete}
    """
  end
end
