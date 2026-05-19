defmodule ReviewsWeb.DeciderComponents do
  @moduledoc """
  Stacked avatar list of the people and agents who reviewed a review.
  """
  use Phoenix.Component

  import ReviewsWeb.CoreComponents, only: [icon: 1]

  @visible_limit 5

  attr :id, :string, default: "decider-stack"
  attr :deciders, :list, default: []

  def decider_stack(%{deciders: []} = assigns) do
    ~H"""
    <div id={@id} class="rev-decider-stack is-empty" aria-label="No published reviews yet">
      <span class="rev-decider-empty">No reviews</span>
    </div>
    """
  end

  def decider_stack(assigns) do
    assigns =
      assigns
      |> assign(:visible_deciders, Enum.take(assigns.deciders, @visible_limit))
      |> assign(:overflow_count, max(length(assigns.deciders) - @visible_limit, 0))

    ~H"""
    <div id={@id} class="rev-decider-stack" aria-label="Published reviews">
      <div
        :for={decider <- @visible_deciders}
        :key={decider.author.id}
        id={"#{@id}-#{decider.author.id}"}
        class="rev-decider"
        title={decider_title(decider)}
        aria-label={decider_title(decider)}
      >
        <div class="rev-decider-avatar">
          <img
            :if={decider.author.avatar_url}
            src={decider.author.avatar_url}
            alt=""
            width="28"
            height="28"
            loading="lazy"
          />
          <span :if={!decider.author.avatar_url} aria-hidden="true">
            {initials(decider.author)}
          </span>
        </div>
        <span class="rev-decider-badge" aria-hidden="true">
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" />
        </span>
      </div>
      <div
        :if={@overflow_count > 0}
        id={"#{@id}-more"}
        class="rev-decider rev-decider-more"
        title={"#{@overflow_count} more published reviews"}
        aria-label={"#{@overflow_count} more published reviews"}
      >
        +{@overflow_count}
      </div>
    </div>
    """
  end

  defp decider_title(%{author: author, decision: decision, comment_count: count}) do
    base = "#{author.handle}: #{decision}"

    case count do
      0 -> base
      1 -> base <> " · 1 comment"
      n -> base <> " · #{n} comments"
    end
  end

  defp initials(%{handle: handle}) when is_binary(handle) do
    handle
    |> String.trim()
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp initials(_), do: "?"
end
