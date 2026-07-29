defmodule Reviews.Accounts.Identity do
  @moduledoc """
  A review actor owned by a GitHub-authenticated user.

  Human identities mirror the owner account. Agent identities represent tools
  or automations that should author reviews, comments, and decisions separately.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @kinds ~w(human agent)

  schema "identities" do
    field :kind, :string
    field :handle, :string
    field :display_name, :string
    field :avatar_url, :string
    field :provider, :string
    field :description, :string

    belongs_to :owner_user, Reviews.Accounts.User
    has_many :api_tokens, Reviews.Accounts.ApiToken

    timestamps(type: :utc_datetime)
  end

  @required ~w(owner_user_id kind handle display_name)a
  @optional ~w(avatar_url provider description)a

  def changeset(identity, attrs) do
    identity
    |> cast(attrs, @required ++ @optional)
    |> update_change(:handle, &normalize_handle/1)
    |> validate_required(@required)
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:handle, min: 1, max: 80)
    |> validate_format(:handle, ~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/)
    |> validate_length(:display_name, min: 1, max: 120)
    |> unique_constraint(:handle, name: :identities_owner_lower_handle_index)
    |> unique_constraint(:owner_user_id, name: :identities_one_human_per_user)
  end

  def kinds, do: @kinds

  defp normalize_handle(handle) when is_binary(handle) do
    handle |> String.trim() |> String.trim_leading("@")
  end

  defp normalize_handle(handle), do: handle
end
