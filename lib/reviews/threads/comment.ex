defmodule Reviews.Threads.Comment do
  @moduledoc """
  A single message in a thread. Lifecycle: `state` starts as "draft" (only
  visible to its author) and flips to "published" atomically when the author
  hits "Publish review".

  Drafts are unique per (thread_id, author_id) where state='draft' — enforced
  by a partial unique index in the migration.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @states ~w(draft published)

  schema "comments" do
    field :body, :string
    field :state, :string, default: "draft"
    field :published_at, :utc_datetime

    belongs_to :thread, Reviews.Threads.Thread
    belongs_to :author, Reviews.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @required ~w(thread_id author_id body)a
  @optional ~w(state published_at)a

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:state, @states)
  end

  def states, do: @states
end
