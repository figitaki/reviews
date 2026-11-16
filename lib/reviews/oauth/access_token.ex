defmodule Reviews.OAuth.AccessToken do
  @moduledoc """
  An access token issued under an identity link. Only its hash is stored.
  """
  use Ecto.Schema

  schema "oauth_access_tokens" do
    field :token_hash, :binary, redact: true
    field :scopes, {:array, :string}
    field :expires_at, :utc_datetime

    belongs_to :identity_link, Reviews.Accounts.IdentityLink

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
