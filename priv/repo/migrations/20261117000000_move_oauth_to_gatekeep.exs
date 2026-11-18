defmodule Reviews.Repo.Migrations.MoveOAuthToGatekeep do
  @moduledoc """
  Moves the OAuth issuer's state to gatekeep's tables, so existing grants,
  refresh tokens, and access tokens keep working after the switch to
  gatekeep. This is gatekeep's one-time copy (figitaki/gatekeep#1):

    * `identity_links` become `gatekeep_grants`, keeping their IDs, so
      comments and refresh tokens still point at the same grant. A link's
      resource is the one its authorization code was issued for, or else the
      latest one of its provider.
    * replaced refresh tokens (`oauth_consumed_refresh_tokens`), so
      presenting one still revokes the grant;
    * unexpired access tokens (`oauth_access_tokens`);
    * registered `rvc_` clients (`oauth_clients`).

  Codes and replay entries live for minutes and aren't copied. Token hashes
  are SHA-256 in both, so nothing is rehashed.

  The old tables stay for one release, so a rollback still finds them. Drop
  `identity_links`, `oauth_authorization_codes`, `oauth_access_tokens`,
  `oauth_consumed_refresh_tokens`, `oauth_clients`, and
  `comments.identity_link_id` in the release after this one ships.
  `oauth_seen_jtis` stays: Poppy Session JWTs still use it.
  """
  use Ecto.Migration

  def up do
    Gatekeep.Storage.Ecto.Migration.up(version: 1)

    alter table(:comments) do
      add :oauth_grant_id, references(:gatekeep_grants, on_delete: :nilify_all)
    end

    create index(:comments, [:oauth_grant_id])

    flush()

    execute """
    INSERT INTO gatekeep_clients (client_id, client_name, redirect_uris, inserted_at)
    SELECT client_id, client_name, redirect_uris, inserted_at FROM oauth_clients
    ON CONFLICT (client_id) DO NOTHING
    """

    # Reviews' refresh tokens last 90 days from the link's creation, which is
    # gatekeep's grant expiry.
    execute """
    INSERT INTO gatekeep_grants
      (id, client_id, client_name, subject, owner, resource, scopes, claims, grant_type,
       refresh_token_hash, dpop_jkt, expires_at, revoked_at, last_used_at, inserted_at,
       updated_at)
    SELECT l.id, l.subject, l.subject_name, l.identity_id::text, l.approved_by_user_id::text,
           COALESCE(own.resource, latest.resource), l.scopes, '{}'::jsonb, 'authorization_code',
           l.refresh_token_hash, l.dpop_jkt, l.inserted_at + interval '90 days',
           l.revoked_at, l.last_used_at, l.inserted_at, l.updated_at
    FROM identity_links l
    LEFT JOIN LATERAL (
      SELECT c.resource FROM oauth_authorization_codes c
      WHERE c.identity_link_id = l.id ORDER BY c.id LIMIT 1
    ) own ON true
    LEFT JOIN LATERAL (
      SELECT c.resource FROM oauth_authorization_codes c
      WHERE c.provider = l.provider ORDER BY c.inserted_at DESC, c.id DESC LIMIT 1
    ) latest ON true
    WHERE COALESCE(own.resource, latest.resource) IS NOT NULL
    """

    execute """
    SELECT setval(pg_get_serial_sequence('gatekeep_grants', 'id'),
                  GREATEST((SELECT max(id) FROM gatekeep_grants), 1))
    """

    execute """
    INSERT INTO gatekeep_consumed_refresh_tokens (grant_id, token_hash, inserted_at)
    SELECT c.identity_link_id, c.token_hash, c.inserted_at
    FROM oauth_consumed_refresh_tokens c
    JOIN gatekeep_grants g ON g.id = c.identity_link_id
    """

    execute """
    INSERT INTO gatekeep_access_tokens
      (token_hash, grant_id, client_id, subject, resource, scopes, dpop_jkt, expires_at,
       inserted_at)
    SELECT t.token_hash, g.id, g.client_id, g.subject, g.resource, t.scopes, t.dpop_jkt,
           t.expires_at, t.inserted_at
    FROM oauth_access_tokens t
    JOIN gatekeep_grants g ON g.id = t.identity_link_id
    WHERE t.expires_at > now()
    """

    execute """
    UPDATE comments c SET oauth_grant_id = c.identity_link_id
    FROM gatekeep_grants g
    WHERE g.id = c.identity_link_id
    """
  end

  def down do
    alter table(:comments) do
      remove :oauth_grant_id
    end

    Gatekeep.Storage.Ecto.Migration.down(version: 1)
  end
end
