defmodule ReviewsWeb.ReviewListLive do
  @moduledoc """
  `/reviews`: the signed-in user's review list.

  Shows the reviews the user's identities wrote or took part in (see
  `Reviews.ReviewIndex` for the rule). Filters live in the URL (`q`, `role`,
  `status`, `author`, `offset`) so a filtered list can be shared or bookmarked.
  Signed-out visitors get a sign-in prompt.
  """
  use ReviewsWeb, :live_view

  alias Reviews.Accounts
  alias Reviews.ReviewIndex
  alias Reviews.Reviews, as: ReviewsContext

  @page_size 25
  @filter_keys ~w(q role status author)

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Reviews")
     |> assign(:current_user, load_current_user(session))
     |> assign(:count, 0)
     |> assign(:offset, 0)
     |> assign(:next_offset, nil)
     |> assign(:now, DateTime.utc_now())
     |> assign(:filters, %{})
     |> assign(:return_to, ~p"/reviews")
     |> assign(:demo_slug, Reviews.DemoReview.slug())
     |> assign(:filter_form, to_form(%{}, as: :filters))
     |> stream_configure(:reviews, dom_id: &"review-#{&1.review.id}")
     |> stream(:reviews, [])}
  end

  @impl true
  def handle_params(params, uri, socket) do
    %URI{path: path, query: query} = URI.parse(uri)

    filters =
      params
      |> Map.take(@filter_keys ++ ["offset"])
      |> Map.put("limit", @page_size)
      |> ReviewIndex.normalize_filters_lenient()

    result = ReviewsContext.list_reviews(socket.assigns.current_user, filters)

    form_params = %{
      "q" => filters.q || "",
      "role" => filters.role,
      "status" => filters.status,
      "author" => filters.author || ""
    }

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:return_to, if(query, do: "#{path}?#{query}", else: path))
     |> assign(:filter_form, to_form(form_params, as: :filters))
     |> assign(:count, length(result.entries))
     |> assign(:offset, result.offset)
     |> assign(:next_offset, result.next_offset)
     |> assign(:now, DateTime.utc_now())
     |> stream(:reviews, result.entries, reset: true)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    filters =
      socket.assigns.filters
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(Map.take(params, @filter_keys))

    {:noreply, push_patch(socket, to: list_path(filters))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/reviews")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="reviews-index" class="l-page design-page">
        <Layouts.landing_topbar
          current_user={@current_user}
          active={:reviews}
          return_to={@return_to}
          show_workflow_anchor={false}
        />

        <div class="design-main rl-main">
          <%= if @current_user do %>
            <.review_list
              streams={@streams}
              filter_form={@filter_form}
              filters={@filters}
              count={@count}
              offset={@offset}
              next_offset={@next_offset}
              now={@now}
              demo_slug={@demo_slug}
            />
          <% else %>
            <div class="design-state-focus is-compact">
              <.ds_empty_state
                icon="hero-queue-list"
                title="Sign in to see your reviews"
                body="Your list has the reviews you wrote or took part in. Review links still work without signing in."
              >
                <:actions>
                  <.ds_github_button
                    id="reviews-sign-in"
                    href={~p"/auth/github?#{[return_to: @return_to]}"}
                  >
                    Sign in with GitHub
                  </.ds_github_button>
                </:actions>
              </.ds_empty_state>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :streams, :map, required: true
  attr :filter_form, :map, required: true
  attr :filters, :map, required: true
  attr :count, :integer, required: true
  attr :offset, :integer, required: true
  attr :next_offset, :integer, default: nil
  attr :now, :any, required: true
  attr :demo_slug, :string, required: true

  defp review_list(assigns) do
    ~H"""
    <style :type={ReviewsWeb.ColocatedCSS}>
      .rl-main {
        padding-top: var(--space-10);
      }

      .rl-layout {
        display: grid;
        gap: var(--space-5);
        width: min(880px, 100%);
        margin: 0 auto;
      }

      /* Header: the page title and the one search field share a row. */
      .rl-header {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--space-5);
      }

      .rl-header h1 {
        margin: 0;
        color: var(--ds-text);
        font-size: var(--font-section-size);
        font-weight: var(--font-section-weight);
        line-height: var(--font-section-leading);
      }

      .rl-search {
        position: relative;
        flex: 0 1 320px;
        min-width: 0;
      }

      .rl-search .hero-magnifying-glass {
        position: absolute;
        top: 50%;
        left: var(--space-4);
        color: var(--ds-faint);
        transform: translateY(-50%);
        pointer-events: none;
      }

      .rl-search .ds-input {
        min-height: 36px;
        padding-left: 32px;
      }

      /* Filters: one row of chips under the header. It scrolls sideways
         on phones instead of wrapping. */
      .rl-chips {
        display: flex;
        align-items: center;
        gap: var(--space-2);
        margin: 0 calc(-1 * var(--space-1));
        padding: var(--space-1);
        overflow-x: auto;
        scrollbar-width: none;
      }

      .rl-chips::-webkit-scrollbar {
        display: none;
      }

      .rl-chip-sep {
        flex-shrink: 0;
        width: var(--border-hair);
        height: 16px;
        background: var(--ds-line);
      }

      .ds-chip.rl-chip-clear {
        border-color: transparent;
        background: transparent;
      }

      /* The list: one panel with divided rows. The title link covers the
         whole row, so the row is the tap target. */
      .rl-list {
        margin: 0;
        padding: 0;
        border: var(--border-hair) solid var(--ds-line);
        border-radius: var(--radius-md);
        background: var(--ds-panel);
        list-style: none;
        overflow: hidden;
      }

      .rl-list:empty {
        display: none;
      }

      .rl-row {
        position: relative;
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        gap: var(--space-1) var(--space-5);
        align-items: center;
        padding: var(--space-5) var(--space-6);
        transition: background-color 160ms ease;
      }

      /* Read rows (nothing waiting for you) step back: a flatter
         background and a regular-weight title. Unread rows keep the panel
         and the semibold title. */
      .rl-row.is-read {
        background: color-mix(in srgb, var(--ds-panel) 40%, var(--ds-bg));
      }

      .rl-row.is-read .rl-title {
        font-weight: var(--weight-regular);
      }

      .rl-row.is-read .rl-title a {
        color: color-mix(in srgb, var(--ds-text) 78%, var(--ds-muted));
      }

      .rl-row + .rl-row {
        border-top: var(--border-hair) solid var(--ds-line);
      }

      .rl-row:hover,
      .rl-row:focus-within {
        background: var(--ds-hover);
      }

      .rl-title {
        min-width: 0;
        margin: 0;
        font-size: var(--font-ui-size);
        font-weight: var(--weight-semi);
        line-height: var(--leading-snug);
      }

      .rl-title a {
        color: var(--ds-text);
        overflow-wrap: anywhere;
        text-decoration: none;
      }

      .rl-title a::after {
        content: "";
        position: absolute;
        inset: 0;
      }

      .rl-title a:focus-visible {
        outline: none;
      }

      .rl-row:has(.rl-title a:focus-visible) {
        outline: 2px solid var(--ds-focus);
        outline-offset: -2px;
      }

      .rl-status {
        display: flex;
        grid-row: 1 / span 2;
        grid-column: 2;
        flex-wrap: wrap;
        justify-content: flex-end;
        gap: var(--space-2);
      }

      .ds-badge.rl-badge-new {
        border-color: color-mix(in srgb, var(--ds-blue) 45%, var(--ds-line));
        color: var(--ds-blue);
      }

      .ds-badge.rl-badge-open {
        border-color: color-mix(in srgb, var(--ds-warn) 45%, var(--ds-line));
        color: var(--ds-warn);
      }

      /* One flex row, so the avatar, handle, dot and time share a centre
         line and no stray whitespace sits between them. */
      .rl-meta {
        display: flex;
        grid-column: 1;
        min-width: 0;
        flex-wrap: wrap;
        align-items: center;
        gap: 0 var(--space-2);
        margin: 0;
        color: var(--ds-muted);
        font-size: var(--font-meta-size);
        line-height: var(--font-meta-leading);
      }

      .rl-dot {
        color: var(--ds-faint);
      }

      /* The author link sits above the row link and filters by author.
         Agent handles can be 80 characters with no break; they wrap inside
         the row instead of clipping. */
      .rl-author {
        position: relative;
        z-index: 1;
        display: inline-flex;
        align-items: center;
        gap: var(--space-2);
        min-width: 0;
        max-width: 100%;
        color: inherit;
        text-decoration: none;
      }

      .rl-author:hover {
        color: var(--ds-text);
        text-decoration: underline;
      }

      .rl-author:focus-visible {
        outline: 2px solid var(--ds-focus);
        outline-offset: 2px;
        border-radius: var(--radius-xs);
      }

      .rl-author > span {
        min-width: 0;
        overflow-wrap: anywhere;
      }

      .rl-author img {
        flex-shrink: 0;
        width: 16px;
        height: 16px;
        border-radius: var(--radius-pill);
        object-fit: cover;
      }

      .rl-empty {
        display: grid;
        place-items: center;
        border: var(--border-hair) dashed var(--ds-line-strong);
        border-radius: var(--radius-md);
        padding: var(--space-12) var(--space-7);
      }

      .rl-empty .ds-empty-actions {
        flex-wrap: wrap;
        justify-content: center;
      }

      .rl-empty-command {
        flex-basis: 100%;
        margin: 0;
        color: var(--ds-muted);
        font-size: var(--font-meta-size);
      }

      .rl-empty-command code {
        border-radius: var(--radius-xs);
        background: var(--ds-hover);
        color: var(--ds-text);
        padding: 2px var(--space-2);
        font-family: var(--font-mono);
        font-size: var(--font-code-size);
      }

      .rl-pager {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: var(--space-5);
        color: var(--ds-muted);
        font-size: var(--font-meta-size);
      }

      .rl-pager-links {
        display: flex;
        gap: var(--space-3);
        margin-left: auto;
      }

      /* PHONE (tokens.css): search takes the header's full width under the
         title, and status badges move under the meta line. */
      @media (max-width: 640px) {
        .rl-main {
          padding-top: var(--space-7);
        }

        .rl-header {
          flex-wrap: wrap;
          gap: var(--space-3);
        }

        .rl-search {
          flex-basis: 100%;
        }

        /* The chip row scrolls sideways. A fade at the right edge says
           there is more, and the .ActiveChip hook keeps a selected chip in
           view. */
        .rl-chips {
          margin-right: calc(-1 * var(--space-7));
          padding-right: var(--space-10);
          mask-image: linear-gradient(to right, currentColor calc(100% - 32px), transparent);
        }

        .rl-row {
          grid-template-columns: minmax(0, 1fr);
          padding: var(--space-5);
        }

        .rl-status {
          grid-row: auto;
          grid-column: 1;
          justify-content: flex-start;
        }
      }

      /* COARSE (tokens.css): a 44px search field; .ds-chip grows its own tap area. */
      @media (pointer: coarse) {
        .rl-search .ds-input {
          min-height: 44px;
        }

        /* Room for .ds-chip's 44px tap area inside the scrolling row. */
        .rl-chips {
          margin-block: calc(-1 * var(--space-3));
          padding-block: var(--space-3);
        }

        /* 16px text keeps iOS Safari from zooming into the field. */
        .rl-search .ds-input {
          font-size: 16px;
        }
      }
    </style>

    <div class="rl-layout">
      <header class="rl-header">
        <h1 id="reviews-title">Reviews</h1>
        <.form
          for={@filter_form}
          id="review-filters"
          class="rl-search"
          phx-change="filter"
          phx-submit="filter"
          role="search"
        >
          <.icon name="hero-magnifying-glass" class="size-4" />
          <label for="filter-q" class="sr-only">Search reviews</label>
          <input
            type="search"
            id="filter-q"
            name={@filter_form[:q].name}
            value={@filter_form[:q].value}
            placeholder="Search titles and slugs"
            autocomplete="off"
            phx-debounce="300"
            class="ds-input"
          />
        </.form>
      </header>

      <nav id="review-chips" class="rl-chips" aria-label="Filters" phx-hook=".ActiveChip">
        <.ds_chip
          :if={@filters.author}
          id="filter-author"
          selected
          patch={list_path(%{@filters | author: nil})}
          aria-label={"Remove author filter @#{@filters.author}"}
        >
          @{@filters.author} <.icon name="hero-x-mark-mini" class="size-3" />
        </.ds_chip>
        <.ds_chip
          :for={{value, label} <- [{"all", "All"}, {"authored", "Mine"}, {"involved", "Taking part"}]}
          id={"filter-role-#{value}"}
          selected={@filters.role == value}
          patch={list_path(%{@filters | role: value})}
        >
          {label}
        </.ds_chip>
        <span class="rl-chip-sep" aria-hidden="true"></span>
        <.ds_chip
          :for={{value, label} <- [{"open", "Open threads"}, {"updated", "New patchset"}]}
          id={"filter-status-#{value}"}
          selected={@filters.status == value}
          patch={list_path(%{@filters | status: toggle(@filters.status, value)})}
        >
          {label}
        </.ds_chip>
        <.ds_chip
          :if={filters_active?(@filters)}
          id="clear-filters"
          patch={~p"/reviews"}
          class="rl-chip-clear"
        >
          Clear
        </.ds_chip>
      </nav>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ActiveChip">
        // On phones the chip row scrolls sideways; bring the last selected
        // chip into view on load and after each filter change.
        export default {
          mounted() { this.reveal() },
          updated() { this.reveal() },
          reveal() {
            const chips = this.el.querySelectorAll(".ds-chip.is-selected")
            const chip = chips[chips.length - 1]
            if (!chip) return
            const box = this.el.getBoundingClientRect()
            const at = chip.getBoundingClientRect()
            if (at.right > box.right - 32) this.el.scrollLeft += at.right - box.right + 48
            else if (at.left < box.left) this.el.scrollLeft += at.left - box.left - 8
          }
        }
      </script>

      <ul id="review-list" class="rl-list" phx-update="stream" aria-labelledby="reviews-title">
        <li
          :for={{dom_id, entry} <- @streams.reviews}
          id={dom_id}
          class={["rl-row", read?(entry) && "is-read"]}
        >
          <h2 class="rl-title">
            <.link navigate={~p"/r/#{entry.review.slug}"}>{entry.review.title}</.link>
          </h2>
          <p class="rl-meta">
            <.link
              patch={list_path(%{@filters | author: entry.review.author.handle})}
              class="rl-author"
              title={"Show reviews by @#{entry.review.author.handle}"}
            >
              <img
                :if={entry.review.author.avatar_url}
                src={entry.review.author.avatar_url}
                alt=""
                width="16"
                height="16"
                loading="lazy"
              />
              <span translate="no">
                @{entry.review.author.handle}{if entry.review.author.kind == "agent",
                  do: " (agent)"}
              </span>
            </.link>
            <span class="rl-dot" aria-hidden="true">·</span>
            <time datetime={DateTime.to_iso8601(entry.updated_at)}>{relative_time(
              entry.updated_at,
              @now
            )}</time>
          </p>
          <div :if={entry.has_new_patchset or entry.open_thread_count > 0} class="rl-status">
            <span :if={entry.has_new_patchset} class="ds-badge rl-badge-new">New patchset</span>
            <span :if={entry.open_thread_count > 0} class="ds-badge rl-badge-open">
              {entry.open_thread_count} open
            </span>
          </div>
        </li>
      </ul>

      <div :if={@count == 0} id="reviews-empty" class="rl-empty">
        <.ds_empty_state
          icon={empty_icon(@filters, @offset)}
          title={empty_title(@filters, @offset)}
          body={empty_body(@filters, @offset)}
        >
          <:actions>
            <%= cond do %>
              <% @offset > 0 -> %>
                <.ds_button
                  id="empty-first-page"
                  patch={list_path(@filters)}
                  icon="hero-arrow-uturn-left"
                >
                  Go to the first page
                </.ds_button>
              <% filters_active?(@filters) -> %>
                <.ds_button id="empty-clear" patch={~p"/reviews"} icon="hero-x-mark">
                  Clear filters
                </.ds_button>
              <% true -> %>
                <p class="rl-empty-command">
                  Run <code translate="no">reviews push</code> in a checkout.
                </p>
                <.ds_button
                  id="empty-demo"
                  navigate={~p"/r/#{@demo_slug}"}
                  icon="hero-book-open"
                >
                  Open the demo review
                </.ds_button>
            <% end %>
          </:actions>
        </.ds_empty_state>
      </div>

      <nav
        :if={@offset > 0 or @next_offset}
        id="review-pager"
        class="rl-pager"
        aria-label="Pages"
      >
        <span :if={@count > 0} id="pager-range">Showing {@offset + 1} to {@offset + @count}</span>
        <span class="rl-pager-links">
          <.ds_button
            :if={@offset > 0}
            id="pager-newer"
            patch={list_path(@filters, newer_offset(@offset, @count, @filters.limit))}
            icon="hero-chevron-left"
          >
            Newer
          </.ds_button>
          <.ds_button
            :if={@next_offset}
            id="pager-older"
            patch={list_path(@filters, @next_offset)}
          >
            Older
            <:trailing><.icon name="hero-chevron-right" class="ds-button-icon" /></:trailing>
          </.ds_button>
        </span>
      </nav>
    </div>
    """
  end

  # Unread means something is waiting for you: a patchset newer than your
  # last action, or open threads. Nothing records opening a review, so this
  # is the closest signal the index has.
  defp read?(entry), do: not entry.has_new_patchset and entry.open_thread_count == 0

  # A second tap on the selected status chip turns that filter off.
  defp toggle(value, value), do: "all"
  defp toggle(_current, value), do: value

  defp list_path(filters, offset \\ 0) do
    params =
      filters
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.take(@filter_keys)
      |> Map.put("offset", offset)
      |> Enum.reject(fn {k, v} -> default_param?(k, v) end)

    ~p"/reviews?#{params}"
  end

  defp default_param?(_key, nil), do: true
  defp default_param?(_key, ""), do: true
  defp default_param?("offset", 0), do: true
  defp default_param?(key, "all") when key in ["role", "status"], do: true
  defp default_param?(_key, _value), do: false

  defp filters_active?(filters) do
    filters
    |> Map.take([:q, :role, :status, :author])
    |> Enum.any?(fn {key, value} -> not default_param?(Atom.to_string(key), value) end)
  end

  # Past the last page (a stale or hand-edited URL) "Newer" goes to the start.
  defp newer_offset(_offset, 0, _limit), do: 0
  defp newer_offset(offset, _count, limit), do: max(offset - limit, 0)

  defp empty_icon(filters, offset) do
    if offset > 0 or filters_active?(filters),
      do: "hero-magnifying-glass",
      else: "hero-inbox"
  end

  defp empty_title(_filters, offset) when offset > 0, do: "No reviews on this page"

  defp empty_title(filters, _offset),
    do: if(filters_active?(filters), do: "No reviews match", else: "Nothing here yet")

  defp empty_body(_filters, offset) when offset > 0,
    do: "This page is past the end of the list."

  defp empty_body(filters, _offset) do
    if filters_active?(filters),
      do: "Try another search, or clear the filters to see all your reviews.",
      else: "Reviews you push, and reviews you comment on, show up here."
  end

  @doc false
  def relative_time(%DateTime{} = at, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, at, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}min ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds < 86_400 * 30 -> "#{div(seconds, 86_400)}d ago"
      true -> Calendar.strftime(at, "%Y-%m-%d")
    end
  end

  defp load_current_user(session) do
    case session["current_user_id"] do
      id when is_integer(id) ->
        try do
          Accounts.get_user!(id)
        rescue
          Ecto.NoResultsError -> nil
        end

      _ ->
        nil
    end
  end
end
