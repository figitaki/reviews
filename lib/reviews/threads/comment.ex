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

    belongs_to :identity_link, Reviews.Accounts.IdentityLink

    belongs_to :thread, Reviews.Threads.Thread
    belongs_to :author, Reviews.Accounts.Identity

    timestamps(type: :utc_datetime)
  end

  @required ~w(thread_id author_id body)a

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, @required ++ [:identity_link_id, :attribution])
    |> validate_required(@required)
  end
end
