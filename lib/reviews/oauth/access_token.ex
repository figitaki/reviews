defmodule Reviews.OAuth.AccessToken do
  @moduledoc """
  An access token issued under an identity link. Only its hash is stored.
  `dpop_jkt` is the thumbprint of the DPoP key it is bound to, or nil for a
  Bearer token.
  """
  use Ecto.Schema

  schema "oauth_access_tokens" do
    field :token_hash, :binary, redact: true
    field :scopes, {:array, :string}
    field :expires_at, :utc_datetime
    field :dpop_jkt, :string

    belongs_to :identity_link, Reviews.Accounts.IdentityLink

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
