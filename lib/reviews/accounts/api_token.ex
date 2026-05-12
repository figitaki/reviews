defmodule Reviews.Accounts.ApiToken do
  @moduledoc """
  Opaque API token used by the CLI to authenticate against `/api/v1/*`.

  Tokens are minted in the web settings page. The raw token is shown ONCE
  to the user; only its SHA-256 hash is persisted. On every API request
  we hash the incoming bearer token and look up by `token_hash`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "api_tokens" do
    field :token_hash, :binary
    field :name, :string
    field :last_used_at, :utc_datetime

    belongs_to :user, Reviews.Accounts.User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Used internally by `Reviews.Accounts.mint_token/2`. Callers should not build
  this changeset directly — go through the context so the hash is derived from
  a freshly generated raw token.
  """
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token_hash, :name, :user_id, :last_used_at])
    |> validate_required([:token_hash, :user_id])
    |> unique_constraint(:token_hash)
  end
end
