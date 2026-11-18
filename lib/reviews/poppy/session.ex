defmodule Reviews.Poppy.Session do
  @moduledoc """
  A Poppy Session, keyed by `client_id`, `sid`, and User ID (spec 5.3).
  `identity_id` is the Reviews account the Session first used signed in.
  """
  use Ecto.Schema

  schema "poppy_sessions" do
    field :client_id, :string
    field :sid, :string
    field :sub, :string
    field :agent_id, :string
    field :ended_at, :utc_datetime
    field :last_seen_at, :utc_datetime

    belongs_to :identity, Reviews.Accounts.Identity

    timestamps(type: :utc_datetime)
  end
end
