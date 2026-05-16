defmodule Reviews.PacketSectionDecisions do
  @moduledoc """
  Persistence helpers for per-reviewer packet section decisions.
  """
  import Ecto.Query, warn: false

  alias Reviews.Accounts.User
  alias Reviews.Repo
  alias Reviews.ReviewPacket
  alias Reviews.Reviews.{PacketSectionDecision, Patchset, Review}

  def list_for_review(%Review{id: review_id}, %User{id: author_id}) do
    PacketSectionDecision
    |> where([d], d.review_id == ^review_id and d.author_id == ^author_id)
    |> order_by([d], asc: d.patchset_id, asc: d.section_index)
    |> Repo.all()
  end

  def list_for_review(_review, nil), do: []

  def set_status(%Review{} = review, %Patchset{} = patchset, %User{} = author, attrs) do
    section_index = attrs.section_index

    base_attrs = %{
      review_id: review.id,
      patchset_id: patchset.id,
      author_id: author.id,
      section_index: section_index,
      section_title: attrs.section_title,
      section_fingerprint: attrs.section_fingerprint,
      section_refs: attrs.section_refs,
      status: attrs.status
    }

    %PacketSectionDecision{}
    |> PacketSectionDecision.changeset(base_attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :section_title,
           :section_fingerprint,
           :section_refs,
           :status,
           :updated_at
         ]},
      conflict_target: [:review_id, :patchset_id, :author_id, :section_index]
    )
  end

  def clear_status(%Review{} = review, %Patchset{} = patchset, %User{} = author, section_index) do
    case Repo.get_by(PacketSectionDecision,
           review_id: review.id,
           patchset_id: patchset.id,
           author_id: author.id,
           section_index: section_index
         ) do
      nil -> {:ok, nil}
      %PacketSectionDecision{} = decision -> Repo.delete(decision)
    end
  end

  def section_state(section, decisions, selected_patchset, patchsets) do
    patchset_number_by_id = Map.new(patchsets, &{&1.id, &1.number})

    current =
      Enum.find(decisions, fn decision ->
        selected_patchset &&
          decision.patchset_id == selected_patchset.id &&
          decision.section_index == section.index
      end)

    inherited =
      inherited_decision(section, decisions, selected_patchset, patchset_number_by_id)

    effective =
      case current do
        %{status: "pending"} -> nil
        nil -> inherited
        decision -> decision
      end

    %{
      current: current,
      inherited: inherited,
      effective: effective,
      previous:
        previous_invalidated_decision(
          section,
          decisions,
          selected_patchset,
          patchset_number_by_id
        )
    }
  end

  defp inherited_decision(_section, _decisions, nil, _numbers), do: nil

  defp inherited_decision(section, decisions, selected_patchset, patchset_number_by_id) do
    section
    |> matching_prior_decisions(decisions, selected_patchset, patchset_number_by_id)
    |> Enum.find(fn decision ->
      MapSet.new(decision.section_refs || []) == MapSet.new(section.refs)
    end)
  end

  defp previous_invalidated_decision(_section, _decisions, nil, _numbers), do: nil

  defp previous_invalidated_decision(section, decisions, selected_patchset, patchset_number_by_id) do
    current_refs = MapSet.new(section.refs)

    section
    |> matching_prior_decisions(decisions, selected_patchset, patchset_number_by_id)
    |> Enum.find(fn decision ->
      previous_refs = MapSet.new(decision.section_refs || [])

      Map.get(patchset_number_by_id, decision.patchset_id) == selected_patchset.number - 1 &&
        previous_refs != current_refs
    end)
    |> case do
      nil ->
        nil

      decision ->
        %{
          status: decision.status,
          patchset_number: Map.fetch!(patchset_number_by_id, decision.patchset_id),
          section_index: decision.section_index
        }
    end
  end

  defp matching_prior_decisions(section, decisions, selected_patchset, patchset_number_by_id) do
    current_title = ReviewPacket.normalize_title(section.title)
    current_refs = MapSet.new(section.refs)

    decisions
    |> Enum.filter(fn decision ->
      previous_number = Map.get(patchset_number_by_id, decision.patchset_id)
      previous_refs = MapSet.new(decision.section_refs || [])
      title_match = ReviewPacket.normalize_title(decision.section_title) == current_title
      refs_overlap = MapSet.size(MapSet.intersection(previous_refs, current_refs)) > 0

      previous_number && previous_number < selected_patchset.number &&
        (title_match || refs_overlap)
    end)
    |> Enum.sort_by(&Map.get(patchset_number_by_id, &1.patchset_id), :desc)
  end
end
