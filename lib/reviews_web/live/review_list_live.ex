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
     |> assign(:filter_form, to_form(%{}, as: :filters))
     |> stream_configure(:reviews, dom_id: &"review-#{&1.review.id}")
     |> stream(:reviews, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
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
     |> assign(:filter_form, to_form(form_params, as: :filters))
     |> assign(:count, length(result.entries))
     |> assign(:offset, result.offset)
     |> assign(:next_offset, result.next_offset)
     |> assign(:now, DateTime.utc_now())
     |> stream(:reviews, result.entries, reset: true)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    {:noreply, push_patch(socket, to: list_path(Map.take(params, @filter_keys)))}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, push_patch(socket, to: ~p"/reviews")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} chrome={false}>
      <main id="reviews-index" class="l-page design-page">
        <Layouts.landing_topbar current_user={@current_user} active={:reviews} />

        <div class="design-main is-settings">
          <.ds_page_header
            eyebrow="Reviews"
            title="Your reviews"
            description="Reviews you wrote or took part in, newest first."
            class="is-compact"
          />

          <%= if @current_user do %>
            <.review_list
              streams={@streams}
              filter_form={@filter_form}
              filters={@filters}
              count={@count}
              offset={@offset}
              next_offset={@next_offset}
              now={@now}
            />
          <% else %>
            <div class="design-state-focus">
              <.ds_empty_state
                icon="hero-queue-list"
                title="Sign in to see your reviews"
                body="Your list has the reviews you wrote or took part in. Review links still work without signing in."
              >
                <:actions>
                  <.link href={~p"/auth/github"} class="ds-button is-primary">
                    Sign in with GitHub
                  </.link>
                </:actions>
              </.ds_empty_state>
            </div>
          <% end %>
        </div>
      </main>
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

  defp review_list(assigns) do
    ~H"""
    <style :type={ReviewsWeb.ColocatedCSS}>
      .rl-layout {
        display: grid;
        gap: 16px;
        width: min(1040px, 100%);
        margin: 0 auto;
      }

      .rl-filters {
        display: grid;
        grid-template-columns: minmax(0, 2fr) repeat(3, minmax(0, 1fr)) auto;
        gap: 10px;
        align-items: end;
      }

      .rl-filters .fieldset {
        margin: 0;
        padding: 0;
      }

      .rl-filters .label {
        color: var(--ds-muted);
        font-size: 12px;
        font-weight: 650;
      }

      .rl-clear {
        min-height: 40px;
        margin-bottom: 8px;
      }

      .rl-list {
        display: grid;
        gap: 8px;
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .rl-row {
        display: grid;
        grid-template-columns: minmax(0, 1fr) auto;
        gap: 6px 16px;
        border: 1px solid var(--ds-line);
        border-radius: 8px;
        background: var(--ds-panel);
        padding: 12px 14px;
        transition: border-color 160ms ease, background-color 160ms ease;
      }

      .rl-row:hover,
      .rl-row:focus-within {
        border-color: var(--ds-line-strong);
        background: var(--ds-panel-raised);
      }

      .rl-title {
        display: flex;
        min-width: 0;
        flex-wrap: wrap;
        align-items: baseline;
        gap: 4px 10px;
        margin: 0;
        font-size: 14px;
        font-weight: 720;
        line-height: 1.3;
      }

      .rl-title a {
        min-width: 0;
        overflow-wrap: anywhere;
        color: var(--ds-text);
        text-decoration: none;
      }

      .rl-title a:hover {
        text-decoration: underline;
      }

      .rl-title a:focus-visible {
        outline: 2px solid var(--ds-text);
        outline-offset: 2px;
        border-radius: 2px;
      }

      .rl-slug {
        color: var(--ds-faint);
        font-family: var(--font-mono);
        font-size: 12px;
        font-weight: 500;
      }

      .rl-badges {
        display: flex;
        flex-wrap: wrap;
        justify-content: flex-end;
        gap: 6px;
      }

      .rl-badge-new {
        border-color: color-mix(in srgb, var(--ds-blue) 45%, var(--ds-line));
        color: var(--ds-blue);
      }

      .rl-badge-open {
        border-color: color-mix(in srgb, var(--ds-warn) 45%, var(--ds-line));
        color: var(--ds-warn);
      }

      .rl-meta {
        display: flex;
        grid-column: 1 / -1;
        flex-wrap: wrap;
        align-items: center;
        gap: 4px 14px;
        margin: 0;
        color: var(--ds-muted);
        font-size: 12px;
      }

      .rl-author {
        display: inline-flex;
        align-items: center;
        gap: 6px;
      }

      .rl-author img {
        width: 18px;
        height: 18px;
        border: 1px solid var(--ds-line);
        border-radius: 999px;
        object-fit: cover;
      }

      .rl-pager {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 12px;
        color: var(--ds-muted);
        font-size: 12px;
      }

      .rl-pager-links {
        display: flex;
        gap: 8px;
      }

      @media (max-width: 860px) {
        .rl-filters {
          grid-template-columns: repeat(2, minmax(0, 1fr));
        }

        .rl-filters .rl-search {
          grid-column: 1 / -1;
        }

        .rl-clear {
          margin-bottom: 0;
        }
      }

      @media (max-width: 520px) {
        .rl-row {
          grid-template-columns: minmax(0, 1fr);
        }

        .rl-badges {
          justify-content: flex-start;
        }
      }
    </style>

    <div class="rl-layout">
      <.form
        for={@filter_form}
        id="review-filters"
        class="rl-filters"
        phx-change="filter"
        phx-submit="filter"
        role="search"
      >
        <div class="rl-search">
          <.input
            field={@filter_form[:q]}
            id="filter-q"
            type="search"
            label="Search"
            placeholder="Title or slug"
            autocomplete="off"
            phx-debounce="300"
            class="ds-input"
          />
        </div>
        <.input
          field={@filter_form[:role]}
          id="filter-role"
          type="select"
          label="Role"
          options={[{"All", "all"}, {"I wrote", "authored"}, {"I took part", "involved"}]}
          class="ds-input"
        />
        <.input
          field={@filter_form[:status]}
          id="filter-status"
          type="select"
          label="Status"
          options={[
            {"All", "all"},
            {"Has open threads", "open"},
            {"New patchset for me", "updated"}
          ]}
          class="ds-input"
        />
        <.input
          field={@filter_form[:author]}
          id="filter-author"
          type="text"
          label="Author"
          placeholder="handle"
          autocomplete="off"
          phx-debounce="300"
          class="ds-input"
        />
        <.ds_button
          :if={filters_active?(@filters)}
          id="clear-filters"
          variant="ghost"
          class="rl-clear"
          phx-click="clear_filters"
        >
          Clear
        </.ds_button>
      </.form>

      <ul id="review-list" class="rl-list" phx-update="stream" aria-label="Reviews">
        <li
          :for={{dom_id, entry} <- @streams.reviews}
          id={dom_id}
          class="rl-row"
        >
          <h2 class="rl-title">
            <.link navigate={~p"/r/#{entry.review.slug}"}>{entry.review.title}</.link>
            <span class="rl-slug" translate="no">{entry.review.slug}</span>
          </h2>
          <div class="rl-badges">
            <span :if={entry.has_new_patchset} class="ds-badge rl-badge-new">New patchset</span>
            <span :if={entry.open_thread_count > 0} class="ds-badge rl-badge-open">
              {entry.open_thread_count} open
            </span>
            <span class="ds-badge">{role_label(entry.role)}</span>
          </div>
          <p class="rl-meta">
            <span class="rl-author">
              <img
                :if={entry.review.author.avatar_url}
                src={entry.review.author.avatar_url}
                alt=""
                width="18"
                height="18"
                loading="lazy"
              />
              <span translate="no">@{entry.review.author.handle}</span>
              <span :if={entry.review.author.kind == "agent"}>(agent)</span>
            </span>
            <span>
              {entry.patchset_count} {plural(entry.patchset_count, "patchset")}
            </span>
            <span>
              {entry.thread_count} {plural(entry.thread_count, "thread")}
            </span>
            <span>
              Updated
              <time datetime={DateTime.to_iso8601(entry.updated_at)}>
                {relative_time(entry.updated_at, @now)}
              </time>
            </span>
          </p>
        </li>
      </ul>

      <.ds_empty_state
        :if={@count == 0}
        icon="hero-queue-list"
        title={if(filters_active?(@filters), do: "No reviews match", else: "No reviews yet")}
        body={
          if(filters_active?(@filters),
            do: "Change or clear the filters to see more reviews.",
            else: "Push a diff with reviews push, or comment on a review. It then shows up here."
          )
        }
      />

      <nav
        :if={@offset > 0 or @next_offset}
        id="review-pager"
        class="rl-pager"
        aria-label="Pages"
      >
        <span>Showing {@offset + 1} to {@offset + @count}</span>
        <span class="rl-pager-links">
          <.link
            :if={@offset > 0}
            id="pager-newer"
            patch={list_path(@filters, max(@offset - @filters.limit, 0))}
            class="ds-button"
          >
            Newer
          </.link>
          <.link
            :if={@next_offset}
            id="pager-older"
            patch={list_path(@filters, @next_offset)}
            class="ds-button"
          >
            Older
          </.link>
        </span>
      </nav>
    </div>
    """
  end

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

  defp role_label("authored"), do: "You wrote it"
  defp role_label(_role), do: "You took part"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  @doc false
  def relative_time(%DateTime{} = at, %DateTime{} = now) do
    seconds = max(DateTime.diff(now, at, :second), 0)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3600)} h ago"
      seconds < 86_400 * 30 -> "#{div(seconds, 86_400)} d ago"
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
