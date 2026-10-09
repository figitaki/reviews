defmodule ReviewsWeb.DeciderComponents do
  @moduledoc """
  Stacked avatar list of the people and agents who reviewed a review.

  Takes the deciders built by `Reviews.ReviewDeciders`. The stack shows the
  first five avatars, each ringed in its decision color with a small decision
  badge in the top-left corner, and a `+N` chip for the rest. Hover or focus
  spreads the stack out. Each avatar has a `title` tooltip and screen-reader
  text with the reviewer and their decision.
  """
  use Phoenix.Component

  import ReviewsWeb.CoreComponents, only: [icon: 1]

  @visible_limit 5

  attr :id, :string, default: "decider-stack"
  attr :deciders, :list, default: []

  def decider_stack(%{deciders: []} = assigns) do
    ~H"""
    <div id={@id} class="rev-decider-stack is-empty">
      <span class="rev-decider-empty">No reviews yet</span>
    </div>
    """
  end

  def decider_stack(assigns) do
    {visible, hidden} = Enum.split(assigns.deciders, @visible_limit)

    assigns =
      assigns
      |> assign(:visible_deciders, visible)
      |> assign(:hidden_deciders, hidden)

    ~H"""
    <ul id={@id} class="rev-decider-stack" aria-label="Reviewers">
      <li
        :for={decider <- @visible_deciders}
        :key={decider.author.id}
        id={"#{@id}-#{decider.author.id}"}
        class={["rev-decider", decision_class(decider.decision)]}
        data-decision={decider.decision}
        data-kind={decider.author.kind}
        title={decider_label(decider)}
      >
        <span class="rev-decider-avatar" aria-hidden="true">
          <img
            :if={decider.author.avatar_url}
            src={decider.author.avatar_url}
            alt=""
            width="28"
            height="28"
            loading="lazy"
          />
          <.icon
            :if={!decider.author.avatar_url && decider.author.kind == "agent"}
            name="hero-cpu-chip"
            class="size-4"
          />
          <span :if={!decider.author.avatar_url && decider.author.kind != "agent"}>
            {initials(decider.author)}
          </span>
        </span>
        <span class="rev-decider-badge" aria-hidden="true">
          <.icon name={decision_icon(decider.decision)} class="size-3" />
        </span>
        <span class="sr-only">{decider_label(decider)}</span>
      </li>
      <li
        :if={@hidden_deciders != []}
        id={"#{@id}-more"}
        class="rev-decider rev-decider-more"
        title={overflow_label(@hidden_deciders)}
      >
        <span aria-hidden="true">+{length(@hidden_deciders)}</span>
        <span class="sr-only">{overflow_label(@hidden_deciders)}</span>
      </li>
    </ul>
    """
  end

  defp decider_label(%{author: author} = decider) do
    [
      "#{author_name(author)}: #{decision_label(decider)}",
      comment_label(decider.comment_count)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp author_name(%{kind: "agent", handle: handle}), do: "@#{handle} (agent)"
  defp author_name(%{handle: handle}), do: "@#{handle}"

  defp decision_label(%{decision: "approved", approved: n, section_count: total}),
    do: "approved #{n} of #{total} #{sections(total)}"

  defp decision_label(%{decision: "denied", denied: n, section_count: total}),
    do: "denied #{n} of #{total} #{sections(total)}"

  defp decision_label(%{decision: "ignored"}), do: "ignored"

  defp decision_label(%{decision: "in_progress"} = d) do
    decided = d.approved + d.denied + d.ignored
    "in progress, #{decided} of #{d.section_count} #{sections(d.section_count)} decided"
  end

  defp decision_label(%{decision: "pending"}), do: "no decision on this revision"
  defp decision_label(%{decision: "commented"}), do: "commented"

  defp comment_label(0), do: nil
  defp comment_label(1), do: "1 comment"
  defp comment_label(n), do: "#{n} comments"

  defp sections(1), do: "section"
  defp sections(_), do: "sections"

  defp overflow_label(hidden) do
    names = Enum.map_join(hidden, ", ", &author_name(&1.author))

    "#{length(hidden)} more #{if length(hidden) == 1, do: "reviewer", else: "reviewers"}: #{names}"
  end

  defp decision_class("in_progress"), do: "is-in-progress"
  defp decision_class(decision), do: "is-#{decision}"

  defp decision_icon("approved"), do: "hero-check"
  defp decision_icon("denied"), do: "hero-x-mark"
  defp decision_icon("ignored"), do: "hero-minus"
  defp decision_icon("in_progress"), do: "hero-ellipsis-horizontal"
  defp decision_icon("pending"), do: "hero-clock"
  defp decision_icon(_), do: "hero-chat-bubble-left-ellipsis"

  defp initials(%{handle: handle}) when is_binary(handle) do
    handle
    |> String.trim()
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp initials(_), do: "?"
end
