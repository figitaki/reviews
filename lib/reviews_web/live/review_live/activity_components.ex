defmodule ReviewsWeb.ReviewLive.ActivityComponents do
  @moduledoc """
  Browser-local comment activity. Requires the ReviewActivity hook and review_activity.css.
  Threads must have comments and their authors preloaded.
  """
  use ReviewsWeb, :html

  attr :id, :string, default: "review-activity"
  attr :review, :any, required: true
  attr :threads, :list, required: true
  attr :current_identity, :any, required: true
  attr :patchset_number, :integer, required: true

  def activity(assigns) do
    threads =
      assigns.threads
      |> Enum.map(fn thread ->
        comments =
          Enum.reject(thread.comments, fn comment ->
            assigns.current_identity && comment.author_id == assigns.current_identity.id
          end)

        %{thread | comments: comments}
      end)
      |> Enum.reject(&(&1.comments == []))
      |> Enum.map(fn thread ->
        comments = Enum.sort_by(thread.comments, & &1.id)
        latest = List.last(comments)
        outdated? = Map.get(thread, :anchor_status) == "outdated"
        anchor = thread.anchor || thread.original_anchor

        number =
          if outdated?, do: thread.originating_patchset_number, else: assigns.patchset_number

        %{
          id: to_string(thread.id),
          filePath: thread.file_path,
          line: anchor["line_number_hint"],
          side: thread.side,
          earlierRevision: outdated?,
          href: ~p"/r/#{assigns.review.slug}?#{[patchset: number, thread: thread.id]}",
          insertedAt: DateTime.to_iso8601(latest.inserted_at),
          comments:
            Enum.map(comments, fn comment ->
              %{id: to_string(comment.id), authorId: to_string(comment.author_id)}
            end)
        }
      end)
      |> Enum.sort_by(&{&1.insertedAt, String.to_integer(List.last(&1.comments).id)}, :desc)

    assigns =
      assign(assigns, :activity_data, %{
        reviewId: to_string(assigns.review.id),
        identityId: if(assigns.current_identity, do: to_string(assigns.current_identity.id)),
        # The summary counts every comment, as each thread's own count does;
        # unread state is shown separately.
        commentCount: assigns.threads |> Enum.map(&length(&1.comments)) |> Enum.sum(),
        threads: threads
      })

    ~H"""
    <aside
      id={@id}
      class="review-activity"
      aria-label="Comment activity"
      phx-hook="ReviewActivity"
      phx-update="ignore"
      data-activity={JSON.encode!(@activity_data)}
    >
      <%!-- Phones: one floating menu button holds Comments and, in the guide,
           Sections. Hidden on wider screens, where the rail shows itself. --%>
      <button
        id={"#{@id}-menu-toggle"}
        type="button"
        class="review-quick-toggle"
        data-quick-toggle
        aria-expanded="false"
        aria-controls={"#{@id}-menu"}
        aria-label="Open review menu"
      >
        <.icon name="hero-ellipsis-horizontal" class="review-quick-open" />
        <.icon name="hero-x-mark" class="review-quick-close" />
      </button>
      <div id={"#{@id}-menu"} class="review-quick-menu" data-quick-menu hidden>
        <button
          id={"#{@id}-menu-sections"}
          type="button"
          class="review-quick-item"
          data-quick-sections
          hidden
        >
          <span>Sections</span>
          <.icon name="hero-bars-3" class="review-quick-icon" />
        </button>
        <button
          id={"#{@id}-menu-comments"}
          type="button"
          class="review-quick-item"
          data-quick-comments
        >
          <span>Comments</span>
          <span data-quick-count class="review-activity-count"></span>
          <svg class="review-activity-icon" viewBox="0 0 24 24" aria-hidden="true">
            <path d="M8 10h8M8 14h5M21 12a9 9 0 0 1-9 9H3l1.5-4A9 9 0 1 1 21 12Z" />
          </svg>
        </button>
      </div>
      <details id={"#{@id}-panel"} class="review-activity-panel">
        <summary id={"#{@id}-summary"} class="review-activity-summary">
          <svg class="review-activity-icon" viewBox="0 0 24 24" aria-hidden="true">
            <path d="M8 10h8M8 14h5M21 12a9 9 0 0 1-9 9H3l1.5-4A9 9 0 1 1 21 12Z" />
          </svg>
          <span class="review-activity-label">Comments</span>
          <span data-activity-count class="review-activity-count"></span>
          <%!-- The summary closes the open panel; this shows that it does. --%>
          <svg class="review-activity-close" viewBox="0 0 24 24" aria-hidden="true">
            <path d="M6 6l12 12M18 6 6 18" />
          </svg>
        </summary>
        <div class="review-activity-body">
          <p data-activity-storage class="sr-only">
            Read state is saved in this browser, not your account.
          </p>
          <p data-activity-status class="sr-only" role="status" aria-live="polite">
            Enable JavaScript to see recent comment activity.
          </p>
          <button
            id={"#{@id}-mark-all"}
            type="button"
            data-activity-mark-all
            class="review-activity-mark-all"
            disabled
          >
            Mark all read
          </button>
          <p data-activity-empty class="review-activity-note" hidden>No unread comments.</p>
          <ol
            data-activity-list
            class="review-activity-list"
            aria-label="Threads with unread comments"
          >
          </ol>
        </div>
      </details>
    </aside>
    """
  end
end
