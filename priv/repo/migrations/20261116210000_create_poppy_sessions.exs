defmodule Reviews.Repo.Migrations.CreatePoppySessions do
  use Ecto.Migration

  # Poppy 1.0 on the OAuth issuer (Reviews.OAuth): Sessions, and what a
  # comment's Poppy request verified. Links, codes, tokens, and the replay
  # cache are the issuer's oauth_* tables and identity_links.
  #
  # Preview databases of the earlier, unsplit branch already have all of this,
  # so each step is skipped when its table or column exists.
  def up do
    # Poppy Sessions, keyed by client_id, sid, and User ID (spec 5.3).
    # identity_id is the Reviews account the Session first used signed in.
    create_if_not_exists table(:poppy_sessions) do
      add :client_id, :text, null: false
      add :sid, :text, null: false
      add :sub, :text, null: false
      add :agent_id, :text
      add :identity_id, references(:identities, on_delete: :nilify_all)
      add :ended_at, :utc_datetime
      add :last_seen_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:poppy_sessions, [:client_id, :sid, :sub])

    # IF NOT EXISTS here also skips the foreign key, which Ecto's
    # add_if_not_exists would add a second time.
    execute """
    ALTER TABLE comments
      ADD COLUMN IF NOT EXISTS identity_link_id bigint
        REFERENCES identity_links(id) ON DELETE SET NULL,
      ADD COLUMN IF NOT EXISTS attribution jsonb
    """
  end

  def down do
    alter table(:comments) do
      remove :identity_link_id
      remove :attribution
    end

    drop table(:poppy_sessions)
  end
end
