defmodule Reviews.Repo.Migrations.AddOauthDpopBinding do
  use Ecto.Migration

  # DPoP (RFC 9449) key thumbprints. A link's refresh token and an access token
  # are bound to a key when the token request that issued them carried a DPoP
  # proof (Poppy 1.0, sections 4.4 and 4.5). Null means Bearer. A code is bound
  # when its authorization request named dpop_jkt (RFC 9449 §10).
  #
  # identity_links uses add_if_not_exists: preview databases of the earlier,
  # unsplit Poppy branch already have the column.
  def up do
    alter table(:oauth_authorization_codes) do
      add :dpop_jkt, :string
    end

    alter table(:identity_links) do
      add_if_not_exists :dpop_jkt, :string
    end

    alter table(:oauth_access_tokens) do
      add :dpop_jkt, :string
    end
  end

  def down do
    for table <- [:oauth_authorization_codes, :identity_links, :oauth_access_tokens] do
      alter table(table) do
        remove :dpop_jkt
      end
    end
  end
end
