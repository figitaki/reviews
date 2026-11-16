defmodule Reviews.Threads.Comment do
  @moduledoc """
  A single published message in a thread.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "comments" do
    field :body, :string
    # What an external identity adapter verified about the request that
    # created this comment (`Reviews.ExternalIdentity`). Nil for comments made
    # in the browser or with a bearer API token.
    field :attribution, :map

    # The OAuth grant the comment was posted under, for external identities.
    belongs_to :oauth_grant, Reviews.OAuth.Grant

    belongs_to :thread, Reviews.Threads.Thread
    belongs_to :author, Reviews.Accounts.Identity

    timestamps(type: :utc_datetime)
  end

  @required ~w(thread_id author_id body)a

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, @required ++ [:oauth_grant_id, :attribution])
    |> validate_required(@required)
  end
end
