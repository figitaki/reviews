defmodule Reviews.Accounts.IdentityLink do
  @moduledoc """
  An owner-approved link from an externally authenticated agent to an existing
  Reviews identity.

  The identity stays the actor: comments and decisions keep its ID. A link only
  records that its owner approved `provider`/`subject` (for an OAuth grant, the
  resource's provider and the client's `client_id`) to act as that identity,
  with which scopes, and whether the owner or the client has since revoked it. Other verification methods, such
  as a DID or a Turnkey-held key, add rows with another `provider`; they never
  create a second identity namespace.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "identity_links" do
    field :provider, :string
    field :subject, :string
    # What the external party calls itself. Not verified; show it as a claim.
    field :subject_name, :string
    field :scopes, {:array, :string}, default: []
    field :refresh_token_hash, :binary, redact: true
    # Thumbprint of the DPoP key the refresh token is bound to (Poppy 4.4).
    field :dpop_jkt, :string
    field :revoked_at, :utc_datetime
    field :last_used_at, :utc_datetime

    belongs_to :identity, Reviews.Accounts.Identity
    belongs_to :approved_by_user, Reviews.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :identity_id,
      :approved_by_user_id,
      :provider,
      :subject,
      :subject_name,
      :scopes,
      :refresh_token_hash,
      :dpop_jkt
    ])
    |> validate_required([:identity_id, :approved_by_user_id, :provider, :subject, :scopes])
    |> validate_length(:subject_name, max: 255)
    |> unique_constraint(:refresh_token_hash)
  end
end
