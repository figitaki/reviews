defmodule ReviewsWeb.ReviewLive.ActivityComponents do
  @moduledoc """
  Comment activity: a chat-style log of recent comments, oldest first, with
  browser-local read state. Requires the ReviewActivity hook and
  review_activity.css. Threads must have comments and their authors preloaded.
  """
  use ReviewsWeb, :html

  attr :id, :string, default: "review-activity"
  attr :review, :any, required: true
  attr :threads, :list, required: true
  attr :current_identity, :any, required: true
  attr :patchset_number, :integer, required: true

  # Enough for the recent conversation without sending every comment body.
  @log_limit 100
  @body_chars 280
  @quote_chars 100

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

    log =
      assigns.threads
      |> Enum.flat_map(fn thread ->
        anchor = thread.anchor || thread.original_anchor
        comments = Enum.sort_by(thread.comments, & &1.id)

        number =
          if Map.get(thread, :anchor_status) == "outdated",
            do: thread.originating_patchset_number,
            else: assigns.patchset_number

        comments
        |> Enum.with_index()
        |> Enum.map(fn {comment, index} ->
          previous = if index > 0, do: Enum.at(comments, index - 1)

          %{
            id: to_string(comment.id),
            threadId: to_string(thread.id),
            authorId: to_string(comment.author_id),
            author: author_name(comment.author),
            body: excerpt(comment.body, @body_chars),
            insertedAt: DateTime.to_iso8601(comment.inserted_at),
            filePath: thread.file_path,
            line: anchor && anchor["line_number_hint"],
            side: thread.side,
            href: ~p"/r/#{assigns.review.slug}?#{[patchset: number, thread: thread.id]}",
            replyTo:
              previous &&
                %{
                  author: author_name(previous.author),
                  body: excerpt(previous.body, @quote_chars)
                }
          }
        end)
      end)
      |> Enum.sort_by(&{&1.insertedAt, String.to_integer(&1.id)})
      |> Enum.take(-@log_limit)

    assigns =
      assigns
      |> assign(:empty, log == [])
      |> assign(:activity_data, %{
        reviewId: to_string(assigns.review.id),
        identityId: if(assigns.current_identity, do: to_string(assigns.current_identity.id)),
        # The summary counts every comment, as each thread's own count does;
        # unread state is shown separately.
        commentCount: assigns.threads |> Enum.map(&length(&1.comments)) |> Enum.sum(),
        threads: threads,
        log: log
      })

    ~H"""
    <aside
      id={@id}
      class="review-activity"
      aria-label="Comment activity"
      phx-hook="ReviewActivity"
      phx-update="ignore"
      data-activity={JSON.encode!(@activity_data)}
      data-empty={@empty}
    >
      <%!-- Phones: icon buttons stacked above the section decision button.
           Sections shows only in the Guide; the comments summary below is the
           Comments button. Hidden on wider screens. --%>
      <button
        id={"#{@id}-sections"}
        type="button"
        class="review-quick-button"
        data-quick-sections
        aria-expanded="false"
        aria-controls="review-guide-flyout"
        aria-label="Sections"
        title="Sections"
      >
        <.icon name="hero-bars-3" class="review-quick-icon" />
      </button>
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
          <p class="review-activity-heading" aria-hidden="true">Comments</p>
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
          <ol
            id={"#{@id}-log"}
            data-activity-list
            class="review-activity-log"
            aria-label="Recent comments, oldest first"
          >
          </ol>
        </div>
      </details>
    </aside>
    """
  end

  defp author_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp author_name(%{handle: handle}) when is_binary(handle), do: handle
  defp author_name(_), do: "Someone"

  defp excerpt(nil, _), do: ""

  defp excerpt(body, chars) do
    body = String.trim(body)
    if String.length(body) > chars, do: String.slice(body, 0, chars) <> "…", else: body
  end
end
