defmodule Reviews.Repo.Migrations.CreateOauthIssuer do
  use Ecto.Migration

  # identity_links and oauth_clients use if_not_exists: preview databases of
  # the earlier Poppy and MCP branches already created them.
  def change do
    # An owner-approved binding of an OAuth client to an existing Reviews
    # agent identity, for one resource (provider). Each approved sign-in is
    # one row, and its refresh token is the grant.
    create_if_not_exists table(:identity_links) do
      add :identity_id, references(:identities, on_delete: :delete_all), null: false
      add :approved_by_user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :subject, :text, null: false
      add :subject_name, :string
      add :scopes, {:array, :string}, null: false, default: []
      add :refresh_token_hash, :binary
      add :revoked_at, :utc_datetime
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists index(:identity_links, [:identity_id])
    create_if_not_exists index(:identity_links, [:approved_by_user_id])
    create_if_not_exists index(:identity_links, [:provider, :subject])
    create_if_not_exists unique_index(:identity_links, [:refresh_token_hash])

    create table(:oauth_authorization_codes) do
      add :code_hash, :binary, null: false
      add :client_id, :text, null: false
      add :client_name, :string
      add :redirect_uri, :text, null: false
      add :code_challenge, :string, null: false
      add :scopes, {:array, :string}, null: false
      # The resource (RFC 8707) the code was issued for, and its provider.
      add :provider, :string, null: false
      add :resource, :text, null: false
      add :identity_id, references(:identities, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :identity_link_id, references(:identity_links, on_delete: :nilify_all)
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_authorization_codes, [:code_hash])

    create table(:oauth_access_tokens) do
      add :token_hash, :binary, null: false
      add :identity_link_id, references(:identity_links, on_delete: :delete_all), null: false
      add :scopes, {:array, :string}, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_access_tokens, [:token_hash])
    create index(:oauth_access_tokens, [:identity_link_id])

    # Refresh tokens a rotating grant replaced, kept for the grant's lifetime,
    # so presenting any of them again revokes the grant (reuse detection).
    create table(:oauth_consumed_refresh_tokens) do
      add :identity_link_id, references(:identity_links, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:oauth_consumed_refresh_tokens, [:token_hash])
    create index(:oauth_consumed_refresh_tokens, [:identity_link_id])

    # Clients registered through dynamic client registration (RFC 7591). They
    # are public clients: no secret, PKCE on every authorization.
    create_if_not_exists table(:oauth_clients) do
      add :client_id, :string, null: false
      add :client_name, :string
      add :redirect_uris, {:array, :text}, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create_if_not_exists unique_index(:oauth_clients, [:client_id])

    # Replay cache shared by every server: client assertion jtis, and any
    # other JWT a resource accepts once.
    create table(:oauth_seen_jtis, primary_key: false) do
      add :kind, :string, null: false, primary_key: true
      add :client_id, :text, null: false, primary_key: true
      add :jti, :text, null: false, primary_key: true
      add :expires_at, :utc_datetime, null: false
    end

    create index(:oauth_seen_jtis, [:expires_at])
  end
end
