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
    # The preceding migration already references identities, including agents.
    execute "ALTER TABLE threads DROP CONSTRAINT IF EXISTS threads_resolved_by_id_fkey"

    execute """
    ALTER TABLE threads
    ADD CONSTRAINT threads_resolved_by_id_fkey
    FOREIGN KEY (resolved_by_id) REFERENCES identities(id) ON DELETE SET NULL
    """
  end
end
