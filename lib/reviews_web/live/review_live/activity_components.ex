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

        %{
          id: to_string(thread.id),
          filePath: thread.file_path,
          status:
            if(Map.get(thread, :anchor_status) == "outdated",
              do: "#{thread.status} · earlier revision",
              else: thread.status
            ),
          author: latest.author.display_name || latest.author.handle,
          preview: String.slice(latest.body, 0, 180),
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
      <details id={"#{@id}-panel"} class="review-activity-panel">
        <summary id={"#{@id}-summary"} class="review-activity-summary">
          <span>Comment activity</span>
          <span data-activity-count class="review-activity-count">Recent threads</span>
        </summary>
        <div class="review-activity-body">
          <p data-activity-storage class="review-activity-note">
            Read state is saved in this browser, not your account.
          </p>
          <p data-activity-status class="review-activity-note" role="status" aria-live="polite">
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
          <ol data-activity-list class="review-activity-list" aria-label="Recent comment threads">
          </ol>
        </div>
      </details>
    </aside>
    """
  end
end
