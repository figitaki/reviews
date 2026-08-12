defmodule Reviews.Repo.Migrations.RetargetThreadResolverToIdentities do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE threads DROP CONSTRAINT IF EXISTS threads_resolved_by_id_fkey"

    execute """
    ALTER TABLE threads
    ADD CONSTRAINT threads_resolved_by_id_fkey
    FOREIGN KEY (resolved_by_id) REFERENCES identities(id) ON DELETE SET NULL
    """
  end

  def down do
    # Only drop the constraint. Re-pointing it at `users` was unrollbackable —
    # an agent identity that resolved a thread has no matching users row, so the
    # ADD CONSTRAINT failed and took the whole rollback with it. Dropping leaves
    # 20260522034439 free to remove the column itself, which is the real undo.
    execute "ALTER TABLE threads DROP CONSTRAINT IF EXISTS threads_resolved_by_id_fkey"
  end
end
