defmodule Reviews.Reviews.CodeRepository do
  @moduledoc """
  The code-storage namespace attached to one review. Patchsets in the review
  share Git objects in this repository but use distinct snapshot refs.

  `storage_key` is the opaque provider locator ("reviews/<public_id>"). It and
  `provider_repo_id` are backend-internal and must never reach the browser.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(staging ready failed deleting)
  @backends ~w(disabled code_storage)
  @object_formats ~w(sha1 sha256)

  schema "code_repositories" do
    field :public_id, Ecto.UUID
    field :backend, :string
    field :storage_key, :string
    field :provider_repo_id, :string
    field :object_format, :string, default: "sha1"
    field :status, :string, default: "staging"
    field :last_error, :string
    field :expires_at, :utc_datetime

    belongs_to :review, Reviews.Reviews.Review
    belongs_to :owner, Reviews.Accounts.Identity
    has_many :code_snapshots, Reviews.Reviews.CodeSnapshot

    timestamps(type: :utc_datetime)
  end

  @required ~w(backend storage_key object_format status)a
  @optional ~w(provider_repo_id last_error expires_at)a

  @doc """
  `owner_id` and `review_id` are set programmatically by the context, never
  cast from external attrs.
  """
  def changeset(code_repository, attrs) do
    code_repository
    |> cast(attrs, @required ++ @optional)
    |> put_new_public_id()
    |> validate_required([:public_id | @required])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:backend, @backends)
    |> validate_inclusion(:object_format, @object_formats)
    |> unique_constraint(:public_id)
    |> unique_constraint(:review_id, name: :code_repositories_review_id_index)
  end

  def statuses, do: @statuses
  def object_formats, do: @object_formats

  defp put_new_public_id(changeset) do
    case get_field(changeset, :public_id) do
      nil -> put_change(changeset, :public_id, Ecto.UUID.generate())
      _ -> changeset
    end
  end
end
