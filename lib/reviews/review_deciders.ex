defmodule Reviews.ReviewDeciders do
  @moduledoc """
  Read model for the published reviewers ("deciders") of a review.

  A decider is any identity, human or agent, outside the review owner's account
  (`Reviews.Policy` treats a person and their agents as one account), that has
  a packet section decision on the review or a published comment on it.
  Section decisions are saved as soon as they are made, so they count as
  published.

  Section decisions belong to an account, not one identity. Each account gets
  one review-level decision for the selected patchset, shown on the identity
  that made the account's most recent decision; the account's other identities
  appear only for their comments. The decision comes from the account's
  effective section decisions, using the same
  carry-forward rules as the packet section buttons
  (`PacketSectionDecisions.section_state/4`):

    * `"denied"`      at least one section is denied
    * `"approved"`    every section is approved or ignored, and at least one
                      is approved
    * `"ignored"`     every section is ignored
    * `"in_progress"` some sections have a decision, some do not
    * `"pending"`     decisions exist only on other patchsets and do not carry
                      to this one
    * `"commented"`   no section decisions, only published comments (this is
                      also the only state for reviews without a packet)
  """

  alias Reviews.Accounts.Identity
  alias Reviews.PacketSectionDecisions
  alias Reviews.Repo
  alias Reviews.ReviewPacket
  alias Reviews.Reviews.{Patchset, Review}
  alias Reviews.Threads

  @type decision :: String.t()

  @type decider :: %{
          author: Identity.t(),
          decision: decision(),
          approved: non_neg_integer(),
          denied: non_neg_integer(),
          ignored: non_neg_integer(),
          section_count: non_neg_integer(),
          comment_count: non_neg_integer(),
          last_active_at: DateTime.t() | nil
        }

  @doc """
  Deciders for `review` at `selected_patchset`, oldest activity first.
  """
  @spec list(Review.t(), [Patchset.t()], Patchset.t() | nil) :: [decider()]
  def list(%Review{} = review, patchsets, selected_patchset) do
    owner_account_id = owner_account_id(review)

    decisions =
      review
      |> PacketSectionDecisions.list_visible_for_review()
      |> Enum.reject(&(&1.account_id == owner_account_id))

    comment_authors =
      review.id
      |> Threads.list_comment_authors()
      |> Enum.reject(&same_account?(&1.author, owner_account_id))

    sections = packet_sections(selected_patchset)
    comments_by_author = Map.new(comment_authors, &{&1.author.id, &1})

    # Decisions belong to the account, so roll them up per account and show
    # the result on the identity that made the account's latest decision.
    rollups_by_author =
      decisions
      |> Enum.group_by(& &1.account_id)
      |> Map.new(fn {_account_id, account_decisions} ->
        # Timestamps have one-second precision; on a tie the newer row wins.
        latest =
          Enum.max_by(account_decisions, &{DateTime.to_unix(&1.updated_at), &1.id})

        {latest.author_id, rollup(account_decisions, sections, selected_patchset, patchsets)}
      end)

    (Enum.map(decisions, & &1.author) ++ Enum.map(comment_authors, & &1.author))
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(fn author ->
      rollup = Map.get(rollups_by_author, author.id, rollup([], sections, nil, []))
      comments = Map.get(comments_by_author, author.id)

      rollup
      |> Map.drop([:decisions])
      |> Map.merge(%{
        author: author,
        comment_count: (comments && comments.comment_count) || 0,
        last_active_at: last_active_at(rollup.decisions, comments)
      })
    end)
    |> Enum.reject(&(&1.decision == "commented" and &1.comment_count == 0))
    |> Enum.sort_by(fn %{last_active_at: at, author: author} ->
      {at && DateTime.to_unix(at), String.downcase(author.handle || "")}
    end)
  end

  defp rollup(account_decisions, sections, selected_patchset, patchsets) do
    statuses =
      Enum.map(sections, fn section ->
        state =
          PacketSectionDecisions.section_state(
            section,
            account_decisions,
            selected_patchset,
            patchsets
          )

        # An inherited "pending" pins the section as undecided.
        case state.effective do
          %{status: "pending"} -> nil
          %{status: status} -> status
          nil -> nil
        end
      end)

    counts = Enum.frequencies(statuses)

    %{
      decisions: account_decisions,
      decision: decision(statuses, account_decisions),
      approved: Map.get(counts, "approved", 0),
      denied: Map.get(counts, "denied", 0),
      ignored: Map.get(counts, "ignored", 0),
      section_count: length(sections)
    }
  end

  defp owner_account_id(%Review{author: %Identity{owner_user_id: id}}), do: id

  defp owner_account_id(%Review{author_id: author_id}) do
    case Repo.get(Identity, author_id) do
      %Identity{owner_user_id: id} -> id
      nil -> nil
    end
  end

  defp same_account?(%Identity{owner_user_id: id}, id) when not is_nil(id), do: true
  defp same_account?(_identity, _account_id), do: false

  defp packet_sections(nil), do: []
  defp packet_sections(%Patchset{packet: packet}), do: ReviewPacket.sections(packet || %{})

  defp decision(statuses, author_decisions) do
    decided = Enum.reject(statuses, &is_nil/1)

    cond do
      "denied" in decided -> "denied"
      decided != [] and decided == statuses and "approved" in decided -> "approved"
      decided != [] and decided == statuses -> "ignored"
      decided != [] -> "in_progress"
      Enum.any?(author_decisions, &(&1.status != "pending")) -> "pending"
      true -> "commented"
    end
  end

  defp last_active_at(author_decisions, comments) do
    [comments && comments.last_commented_at | Enum.map(author_decisions, & &1.updated_at)]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end
end
