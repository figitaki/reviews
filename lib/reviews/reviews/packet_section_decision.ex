defmodule Reviews.Reviews.PacketSectionDecision do
  @moduledoc """
  Per-reviewer decision for one packet section in one patchset.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(approved denied ignored pending)

  schema "packet_section_decisions" do
    field :section_index, :integer
    field :section_title, :string
    field :section_fingerprint, :string
    field :section_refs, {:array, :string}, default: []
    field :status, :string

    belongs_to :review, Reviews.Reviews.Review
    belongs_to :patchset, Reviews.Reviews.Patchset
    belongs_to :author, Reviews.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @required ~w(review_id patchset_id author_id section_index section_title section_fingerprint status)a
  @optional ~w(section_refs)a

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:section_index, greater_than_or_equal_to: 0)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:review_id, :patchset_id, :author_id, :section_index],
      name: :packet_section_decisions_one_per_user_section
    )
  end

  def statuses, do: @statuses
end
