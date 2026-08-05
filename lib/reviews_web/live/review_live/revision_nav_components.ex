defmodule ReviewsWeb.ReviewLive.RevisionNavComponents do
  @moduledoc false
  use ReviewsWeb, :html

  attr :nav, :map, required: true
  attr :review, :any, required: true
  attr :live_action, :atom, required: true
  attr :selected_patchset, :any, required: true
  attr :has_packet, :boolean, default: false
  attr :outline_available, :boolean, default: false
  attr :show_packet_outline, :boolean, default: true

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
          <div class="review-revision-copy-main">
            <span class="review-revision-label">
              Revision {@nav.selected_index} of {@nav.revision_count}
            </span>
            <strong class="review-revision-title">
              v{@nav.current_revision.number}
            </strong>
          </div>
          <button
            :if={@outline_available && !@show_packet_outline}
            type="button"
            class="review-nav-button review-outline-toggle"
            phx-click="toggle_packet_outline"
          >
            <.icon name="hero-book-open" class="size-4" /> Show outline
          </button>
        </div>

        <div class="review-revision-controls" aria-label="Revision navigation">
          <div
            :if={@has_packet}
            id="code-view-switcher"
            class="review-code-view-switcher"
            role="tablist"
            aria-label="Code view"
          >
            <.link
              navigate={guide_path(@review, @selected_patchset)}
              class={["review-code-view-tab", @live_action != :changes && "is-active"]}
              role="tab"
              aria-selected={if(@live_action != :changes, do: "true", else: "false")}
            >
              Guide
            </.link>
            <.link
              navigate={diff_path(@review, @selected_patchset)}
              class={["review-code-view-tab", @live_action == :changes && "is-active"]}
              role="tab"
              aria-selected={if(@live_action == :changes, do: "true", else: "false")}
            >
              Diff
            </.link>
          </div>
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

  defp guide_path(review, selected_patchset) do
    suffix = patchset_query(selected_patchset)
    "/r/#{review.slug}#{suffix}"
  end

  defp diff_path(review, selected_patchset) do
    suffix = patchset_query(selected_patchset)
    "/r/#{review.slug}/changes#{suffix}"
  end

  defp patchset_query(nil), do: ""
  defp patchset_query(%{number: number}), do: "?patchset=#{number}"
end
