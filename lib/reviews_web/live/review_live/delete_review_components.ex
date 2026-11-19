defmodule ReviewsWeb.ReviewLive.DeleteReviewComponents do
  @moduledoc """
  The review owner's menu and the dialog that confirms deleting the review.
  The delete button stays disabled until the owner types the review's slug.
  """
  use ReviewsWeb, :html

  def review_menu(assigns) do
    ~H"""
    <div id="review-owner-menu" class="dropdown dropdown-end">
      <button
        tabindex="0"
        type="button"
        class="review-button review-button-secondary"
        aria-label="Review options"
        title="Review options"
      >
        <.icon name="hero-ellipsis-horizontal" class="size-4" />
      </button>
      <ul tabindex="0" class="dropdown-content menu menu-sm review-menu z-20 mt-2 w-44 p-2">
        <li>
          <button
            id="open-delete-review"
            type="button"
            class="review-menu-danger"
            phx-click="open_delete_review"
          >
            Delete review…
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :review, :map, required: true
  attr :summary, :map, required: true
  attr :confirm_slug, :string, required: true

  def dialog(assigns) do
    assigns = assign(assigns, :form, to_form(%{"confirm_slug" => assigns.confirm_slug}))

    ~H"""
    <div
      id="delete-review-dialog"
      class="review-dialog-backdrop"
      phx-window-keydown="cancel_delete_review"
      phx-key="Escape"
    >
      <section
        class="review-modal review-delete-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="delete-review-title"
        aria-describedby="delete-review-impact"
      >
        <h2 id="delete-review-title" class="review-modal-title">Delete this review?</h2>
        <p id="delete-review-impact">
          This deletes <strong translate="no">{@review.title}</strong>
          for everyone: {count(@summary.patchsets, "revision")}, {count(@summary.threads, "thread")} and {count(
            @summary.comments,
            "comment"
          )}, with every section decision and viewed mark. It can't be undone.
        </p>
        <p
          :if={@summary.other_comments > 0}
          id="delete-review-others-warning"
          class="review-delete-warning"
        >
          <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
          <span>
            {count(@summary.other_comments, "comment")} by other people or agents will be deleted too ({Enum.join(
              @summary.other_authors,
              ", "
            )}).
          </span>
        </p>
        <.form
          for={@form}
          id="delete-review-form"
          phx-change="change_delete_review"
          phx-submit="delete_review"
        >
          <.input
            field={@form[:confirm_slug]}
            id="delete-review-confirm"
            type="text"
            label={"Type #{@review.slug} to confirm"}
            class="review-delete-input"
            autocomplete="off"
            spellcheck="false"
            phx-mounted={JS.focus()}
          />
          <div class="review-delete-actions">
            <button
              id="cancel-delete-review"
              type="button"
              class="review-button review-button-secondary"
              phx-click="cancel_delete_review"
            >
              Cancel
            </button>
            <button
              id="confirm-delete-review"
              type="submit"
              class="review-button review-button-danger"
              disabled={String.trim(@confirm_slug) != @review.slug}
            >
              Delete review
            </button>
          </div>
        </.form>
      </section>
    </div>
    """
  end

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
