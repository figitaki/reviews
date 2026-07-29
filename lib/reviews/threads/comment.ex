defmodule Reviews.Threads.Comment do
  @moduledoc """
  A single published message in a thread.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "comments" do
    field :body, :string

    belongs_to :thread, Reviews.Threads.Thread
    belongs_to :author, Reviews.Accounts.Identity

    timestamps(type: :utc_datetime)
  end

  @required ~w(thread_id author_id body)a

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, @required)
    |> validate_required(@required)
  end
end
