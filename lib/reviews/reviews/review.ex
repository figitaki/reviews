defmodule Reviews.Reviews.Review do
  @moduledoc """
  Top-level review entity. Has many patchsets (1, 2, 3...).
  Identified externally by `slug` (URL-safe random ID).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "reviews" do
    field :slug, :string
    field :title, :string
    field :description, :string
    field :visibility, :string, default: "link"
    field :published_at, :utc_datetime

    belongs_to :author, Reviews.Accounts.User
    has_many :patchsets, Reviews.Reviews.Patchset

    timestamps(type: :utc_datetime)
  end

  @required ~w(slug title author_id)a
  @optional ~w(description visibility published_at)a
  @visibilities ~w(link public)

  def changeset(review, attrs) do
    review
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:visibility, @visibilities)
    |> unique_constraint(:slug)
  end
end
