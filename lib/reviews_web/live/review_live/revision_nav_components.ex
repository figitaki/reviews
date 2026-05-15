defmodule ReviewsWeb.ReviewLive.RevisionNavComponents do
  @moduledoc false
  use ReviewsWeb, :html

  attr :nav, :map, required: true
  attr :selected_patchset, :any, required: true

  def revision_nav(assigns) do
    ~H"""
    <section
      :if={@selected_patchset && @nav.rounds != []}
      id="revision-nav"
      class="review-revision-nav"
      aria-label="Review rounds and turns"
    >
      <div class="review-round-nav">
        <div class="review-revision-copy">
          <span class="review-revision-label">
            Round {@nav.current_round.index} of {@nav.round_count}
          </span>
          <strong class="review-revision-title">
            {@nav.current_round.title}
          </strong>
        </div>

        <div class="review-revision-controls" aria-label="Round navigation">
          <button
            type="button"
            class="review-nav-button"
            phx-click="select_patchset"
            phx-value-number={@nav.previous_round && @nav.previous_round.start_number}
            disabled={!@nav.previous_round}
            aria-label="Previous round"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Round
          </button>
          <div class="review-round-chip-list" aria-label="Rounds">
            <button
              :for={round <- @nav.rounds}
              type="button"
              class={[
                "review-round-chip",
                round.index == @nav.current_round.index && "is-active"
              ]}
              phx-click="select_patchset"
              phx-value-number={round.start_number}
              aria-pressed={if(round.index == @nav.current_round.index, do: "true", else: "false")}
              title={round.title}
            >
              {round.index}
            </button>
          </div>
          <button
            type="button"
            class="review-nav-button"
            phx-click="select_patchset"
            phx-value-number={@nav.next_round && @nav.next_round.start_number}
            disabled={!@nav.next_round}
            aria-label="Next round"
          >
            Round <.icon name="hero-arrow-right" class="size-4" />
          </button>
        </div>
      </div>

      <div class="review-turn-nav">
        <div class="review-revision-copy">
          <span class="review-revision-label">
            Turn {@nav.selected_turn_index} of {@nav.current_round.turn_count}
          </span>
          <span class="review-turn-range">
            v{@nav.current_round.start_number}
            <%= if @nav.current_round.end_number != @nav.current_round.start_number do %>
              -v{@nav.current_round.end_number}
            <% end %>
          </span>
        </div>

        <div class="review-revision-controls" aria-label="Turn navigation">
          <button
            type="button"
            class="review-nav-button"
            phx-click="select_patchset"
            phx-value-number={@nav.previous_turn && @nav.previous_turn.number}
            disabled={!@nav.previous_turn}
            aria-label="Previous turn"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Turn
          </button>
          <div class="review-turn-chip-list" aria-label="Turns in this round">
            <button
              :for={turn <- @nav.current_round.turns}
              id={"patchset-#{turn.number}"}
              type="button"
              class={[
                "review-turn-chip",
                turn.number == @selected_patchset.number && "is-active",
                turn.packet_present && "has-packet"
              ]}
              phx-click="select_patchset"
              phx-value-number={turn.number}
              aria-pressed={if(turn.number == @selected_patchset.number, do: "true", else: "false")}
              title={
                if(turn.packet_present,
                  do: "v#{turn.number} has a review packet",
                  else: "v#{turn.number}"
                )
              }
            >
              v{turn.number}
            </button>
          </div>
          <button
            type="button"
            class="review-nav-button"
            phx-click="select_patchset"
            phx-value-number={@nav.next_turn && @nav.next_turn.number}
            disabled={!@nav.next_turn}
            aria-label="Next turn"
          >
            Turn <.icon name="hero-arrow-right" class="size-4" />
          </button>
        </div>
      </div>
    </section>
    """
  end
end
