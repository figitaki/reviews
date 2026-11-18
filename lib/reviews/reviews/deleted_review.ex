defmodule Reviews.Reviews.DeletedReview do
  @moduledoc """
  The slug of a review its owner deleted, and when. Nothing else about the
  review is kept; this only lets its link say "This review was deleted".
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "deleted_reviews" do
    field :slug, :string
    field :deleted_at, :utc_datetime
  end
end
