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
    # Put back the constraint that 20260522034439 creates. Do not point it at
    # `users`: an agent identity that resolved a thread has no users row, so
    # that ADD CONSTRAINT fails. Do not leave it dropped: the rollback of
    # 20260522034439 removes the column through `references/2`, and it fails
    # when the constraint is missing.
    execute "ALTER TABLE threads DROP CONSTRAINT IF EXISTS threads_resolved_by_id_fkey"

    execute """
    ALTER TABLE threads
    ADD CONSTRAINT threads_resolved_by_id_fkey
    FOREIGN KEY (resolved_by_id) REFERENCES identities(id) ON DELETE SET NULL
    """
  end
end
