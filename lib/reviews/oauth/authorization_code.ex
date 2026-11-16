defmodule Reviews.OAuth.AuthorizationCode do
  @moduledoc "A one-time authorization code. Only its hash is stored."
  use Ecto.Schema

  schema "oauth_authorization_codes" do
    field :code_hash, :binary, redact: true
    field :client_id, :string
    field :client_name, :string
    field :redirect_uri, :string
    field :code_challenge, :string
    field :scopes, {:array, :string}
    # The resource the code was issued for (RFC 8707) and its links' provider.
    field :provider, :string
    field :resource, :string
    field :expires_at, :utc_datetime
    field :consumed_at, :utc_datetime

    belongs_to :identity, Reviews.Accounts.Identity
    belongs_to :user, Reviews.Accounts.User
    belongs_to :identity_link, Reviews.Accounts.IdentityLink

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
