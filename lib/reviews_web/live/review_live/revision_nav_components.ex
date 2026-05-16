defmodule ReviewsWeb.ReviewLive.RevisionNavComponents do
  @moduledoc false
  use ReviewsWeb, :html

  attr :nav, :map, required: true
  attr :review, :any, required: true
  attr :live_action, :atom, required: true
  attr :selected_patchset, :any, required: true

  def revision_nav(assigns) do
    ~H"""
    <section
      :if={@selected_patchset && @nav.revisions != []}
      id="revision-nav"
      class="review-revision-nav"
      aria-label="Review revisions"
    >
      <div class="review-revision-row">
        <div class="review-revision-copy">
          <span class="review-revision-label">
            Revision {@nav.selected_index} of {@nav.revision_count}
          </span>
          <strong class="review-revision-title">
            v{@nav.current_revision.number}
          </strong>
        </div>

        <div class="review-revision-controls" aria-label="Revision navigation">
          <.link
            navigate={revision_mode_path(@review, @selected_patchset, @live_action)}
            class="review-nav-button"
          >
            {if(@live_action == :changes, do: "Packet", else: "Changes")}
          </.link>
          <button
            type="button"
            class="review-nav-button"
            phx-click="select_patchset"
            phx-value-number={@nav.previous_revision && @nav.previous_revision.number}
            disabled={!@nav.previous_revision}
            aria-label="Previous revision"
          >
            <.icon name="hero-arrow-left" class="size-4" />
            <span class="review-nav-button-label">Revision</span>
          </button>
          <div class="review-revision-chip-list" aria-label="Revisions">
            <button
              :for={revision <- @nav.revisions}
              id={"patchset-#{revision.number}"}
              type="button"
              class={[
                "review-revision-chip",
                revision.number == @selected_patchset.number && "is-active",
                revision.packet_present && "has-packet"
              ]}
              phx-click="select_patchset"
              phx-value-number={revision.number}
              aria-pressed={
                if(revision.number == @selected_patchset.number, do: "true", else: "false")
              }
              title={
                if(revision.packet_present,
                  do: "v#{revision.number} has a review packet",
                  else: "v#{revision.number}"
                )
              }
            >
              v{revision.number}
            </button>
          </div>
          <button
            type="button"
            class="review-nav-button"
            phx-click="select_patchset"
            phx-value-number={@nav.next_revision && @nav.next_revision.number}
            disabled={!@nav.next_revision}
            aria-label="Next revision"
          >
            <span class="review-nav-button-label">Revision</span>
            <.icon name="hero-arrow-right" class="size-4" />
          </button>
        </div>
      </div>
    </section>
    """
  end

  defp revision_mode_path(review, selected_patchset, :changes) do
    suffix = patchset_query(selected_patchset)
    "/r/#{review.slug}#{suffix}"
  end

  defp revision_mode_path(review, selected_patchset, _action) do
    suffix = patchset_query(selected_patchset)
    "/r/#{review.slug}/changes#{suffix}"
  end

  defp patchset_query(nil), do: ""
  defp patchset_query(%{number: number}), do: "?patchset=#{number}"
end
