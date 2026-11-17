defmodule Reviews.PacketSectionDecisions do
  @moduledoc """
  Packet section decisions, one per account, section and patchset.

  An account is a person and their agent identities, so the owner's human and
  agent identities share one decision per section; each decision records the
  identity that made it as `author`. Only identities allowed to decide
  sections (`Reviews.Policy`, today the review owner) may write them; anyone
  else gets `{:error, :forbidden}`.

  Writes run in a transaction that locks the patchset row and load the current
  decisions inside it, so concurrent writers never act on stale state.

    * `decide/5` sets an explicit status. Setting the status a section already
      has changes nothing, so a retried request is safe. The API uses it.
    * `toggle/5` is the review page's button: choosing the current status again
      clears it, and choosing an inherited status pins it as pending.
  """
  import Ecto.Query, warn: false

  alias Reviews.Accounts.{Identity, User}
  alias Reviews.Policy
  alias Reviews.Principal
  alias Reviews.Repo
  alias Reviews.ReviewPacket
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.{PacketSectionDecision, Patchset, Review}

  @statuses ~w(approved denied ignored pending)

  @doc "The decisions of the viewer's account on this review, oldest patchset first."
  def list_for_review(%Review{} = review, %Principal{identity: identity}),
    do: list_for_review(review, identity)

  def list_for_review(%Review{} = review, %Identity{owner_user_id: account_id})
      when not is_nil(account_id),
      do: list_for_account(review, account_id)

  def list_for_review(%Review{} = review, %User{id: account_id}),
    do: list_for_account(review, account_id)

  def list_for_review(_review, _viewer), do: []

  defp list_for_account(%Review{id: review_id}, account_id) do
    PacketSectionDecision
    |> where([d], d.review_id == ^review_id and d.account_id == ^account_id)
    |> order_by([d], asc: d.patchset_id, asc: d.section_index)
    |> Repo.all()
  end

  @doc """
  Sets the actor's account decision for `section` on `patchset` to `status`
  (`"approved"`, `"denied"`, `"ignored"`, or `"pending"`). When the section
  already has that status, nothing changes, including who made the decision.
  Returns `{:ok, decision}`.
  """
  def decide(%Review{} = review, %Patchset{} = patchset, actor, section, status)
      when status in @statuses do
    locked(review, patchset, actor, fn identity, _decisions ->
      put(review, patchset, identity, section, status)
    end)
  end

  @doc """
  The review page's decision button. Choosing the section's current status
  clears it (back to any inherited decision), and choosing the inherited
  status pins the section as pending. Returns `{:ok, decision | nil}`.
  """
  def toggle(%Review{} = review, %Patchset{} = patchset, actor, section, status)
      when status in ["approved", "denied", "ignored"] do
    locked(review, patchset, actor, fn identity, decisions ->
      patchsets = ReviewsContext.list_patchset_summaries(review)
      state = section_state(section, decisions, patchset, patchsets)

      cond do
        state.current && state.current.status == status ->
          Repo.delete!(state.current)
          nil

        is_nil(state.current) && state.inherited && state.inherited.status == status ->
          put(review, patchset, identity, section, "pending")

        true ->
          put(review, patchset, identity, section, status)
      end
    end)
  end

  # Checks the policy, then runs `fun` with the acting identity and the
  # account's current decisions while holding the patchset row lock. `NO KEY
  # UPDATE` does not block comments and files that reference the patchset.
  defp locked(review, patchset, actor, fun) do
    with %Principal{identity: identity} <- Principal.from(actor),
         true <- Policy.can?(actor, :decide_section, review) do
      Repo.transaction(fn ->
        Repo.one!(
          from p in Patchset, where: p.id == ^patchset.id, lock: "FOR NO KEY UPDATE", select: p.id
        )

        fun.(identity, list_for_review(review, identity))
      end)
    else
      _ -> {:error, :forbidden}
    end
  end

  defp put(review, patchset, identity, section, status) do
    existing =
      Repo.get_by(PacketSectionDecision,
        review_id: review.id,
        patchset_id: patchset.id,
        account_id: identity.owner_user_id,
        section_index: section.index
      )

    attrs = %{
      review_id: review.id,
      patchset_id: patchset.id,
      account_id: identity.owner_user_id,
      author_id: identity.id,
      section_index: section.index,
      section_title: section.title,
      section_fingerprint: section.fingerprint,
      section_refs: section.refs,
      status: status
    }

    case existing do
      %PacketSectionDecision{status: ^status} -> existing
      nil -> %PacketSectionDecision{} |> PacketSectionDecision.changeset(attrs) |> write()
      _ -> existing |> PacketSectionDecision.changeset(attrs) |> write()
    end
  end

  defp write(%Ecto.Changeset{data: %{id: nil}} = changeset), do: insert_or_rollback(changeset)

  defp write(changeset) do
    case Repo.update(changeset) do
      {:ok, decision} -> decision
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, decision} -> decision
      {:error, changeset} -> Repo.rollback(changeset)
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
