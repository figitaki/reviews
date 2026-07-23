defmodule Reviews.Repo.Migrations.FixIdentityHandleUniqueIndexIdempotently do
  use Ecto.Migration

  # 20260522025819_add_agent_identities.exs originally created a case-sensitive
  # unique_index(:identities, [:owner_user_id, :handle]). A later commit edited
  # that same migration file in place to switch to a case-insensitive
  # lower(handle) index instead of adding a new migration. Any database that
  # had already run the original migration (this PR's own preview deploy
  # included) recorded that version as applied and never picked up the edit,
  # so it silently kept the case-sensitive index — letting handles like
  # "claude" and "CLAUDE" collide for the same owner. This migration corrects
  # that in place, regardless of which index variant a given database has.
  def up do
    execute "DROP INDEX IF EXISTS identities_owner_user_id_handle_index"

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS identities_owner_lower_handle_index
    ON identities (owner_user_id, lower(handle))
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS identities_owner_lower_handle_index"

    execute """
    CREATE UNIQUE INDEX IF NOT EXISTS identities_owner_user_id_handle_index
    ON identities (owner_user_id, handle)
    """
  end
end
