defmodule Reviews.Repo.Migrations.CreateAuthRelayCodes do
  use Ecto.Migration

  # Nonces of preview sign-in relay codes this app has redeemed, so each code
  # works once. See Reviews.AuthRelay.
  def change do
    create table(:auth_relay_codes, primary_key: false) do
      add :nonce, :string, primary_key: true
      add :inserted_at, :naive_datetime, null: false
    end
  end
end
