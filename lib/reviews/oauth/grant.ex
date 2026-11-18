defmodule Reviews.OAuth.Grant do
  @moduledoc """
  A gatekeep grant, as Reviews reads it: an owner's approval of one client
  acting as one of their agent identities at one resource. Its `subject` is
  the agent identity's ID and its `owner` the approving user's ID, both as
  strings; `Reviews.OAuth` loads them into `identity` and `approved_by_user`.

  The rows live in gatekeep's `gatekeep_grants` table
  (`Gatekeep.Storage.Ecto`). Reviews only reads them, so comments can point
  at the grant they were posted under. Gatekeep writes them.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "gatekeep_grants" do
    field :client_id, :string
    # What the client calls itself. Not verified; show it as a claim.
    field :client_name, :string
    field :subject, :string
    field :owner, :string
    field :resource, :string
    field :scopes, {:array, :string}, default: []
    # Thumbprint of the DPoP key the refresh token is bound to (Poppy 4.4).
    field :dpop_jkt, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :last_used_at, :utc_datetime

    field :identity, :any, virtual: true
    field :approved_by_user, :any, virtual: true

    timestamps(type: :utc_datetime)
  end
end
