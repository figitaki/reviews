defmodule Reviews.Accounts.User do
  @moduledoc """
  A GitHub-authenticated user.

  Identified primarily by `github_id` (the numeric ID GitHub assigns, stable
  across username changes). `username`, `avatar_url`, and `email` are mirrored
  in for display + outbound notifications.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :github_id, :integer
    field :username, :string
    field :avatar_url, :string
    field :email, :string
    field :preferences, :map, default: %{}

    has_many :api_tokens, Reviews.Accounts.ApiToken
    has_many :identities, Reviews.Accounts.Identity, foreign_key: :owner_user_id

    timestamps(type: :utc_datetime)
  end

  @required ~w(github_id username)a
  @optional ~w(avatar_url email)a

  def changeset(user, attrs) do
    user
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:github_id)
  end
end
