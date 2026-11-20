defmodule Reviews.Repo.Migrations.EnsureAuthRelayCodes do
  use Ecto.Migration

  # 20261116120000_create_auth_relay_codes shares its version with a migration
  # from an earlier version of PR #167, so a database that ran that one counts
  # it as done and never gets this table. The relay then fails after GitHub
  # sign-in. Creates the table only where it is missing.
  def change do
    create_if_not_exists table(:auth_relay_codes, primary_key: false) do
      add :nonce, :string, primary_key: true
      add :inserted_at, :naive_datetime, null: false
    end
  end
end
