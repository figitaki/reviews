defmodule ReviewsWeb.DesignComponentsLive do
  @moduledoc """
  `/design/components`: the review page's composite components, mounted
  from their real code with sample data (`ReviewsWeb.DesignFixtures`), so
  they can be tried and changed in one place.

  Replies, resolving and new comments change only the page; nothing is
  saved. `/design/components/phone` renders the floating buttons alone, for
  the phone-sized frame on the main page: their layout follows the
  viewport, so only a narrow frame shows the phone version.

  On and off with `/design` (`ReviewsWeb.DesignLive.enabled?/0`).
  """
  use ReviewsWeb, :live_view

  alias Reviews.ReviewView
  alias ReviewsWeb.{DesignFixtures, DesignLive}
  alias ReviewsWeb.ReviewLive.{ActivityComponents, PacketComponents}

  @hunk_id "dcp-hunk"

  # Section decision samples: {index, status, who is looking}. Light-theme
  # copies use index + 10 so ids stay unique.
  @decision_samples [
    {0, "pending", :owner},
    {1, "approved", :owner},
    {2, "denied", :reviewer},
    {3, "pending", :signed_out}
  ]

  @impl true
  def mount(_params, _session, socket) do
    unless DesignLive.enabled?(), do: raise(DesignLive.Disabled)

    threads = DesignFixtures.threads()

    decisions =
      for {index, status, _who} <- @decision_samples, offset <- [0, 10], into: %{} do
        {index + offset, %{status: status, editing: false}}
      end

    {:ok,
     assign(socket,
       page_title: "Component playground",
       threads: threads,
       threads_json:
         JSON.encode!(
           ReviewView.thread_payloads_for_file(
             %{published_threads: threads},
             DesignFixtures.file_path()
           )
         ),
       viewer: DesignFixtures.viewer(),
       decisions: decisions,
       decision_samples: @decision_samples,
       hunk_id: @hunk_id,
       expanded_hunk_ids: MapSet.new([@hunk_id]),
       hunk_viewed: false,
       opened: nil
     )}
  end

  # The Comments log asks the review page to open a thread; say which.
  @impl true
  def handle_event("open_activity_thread", %{"thread_id" => id}, socket) do
    {:noreply, assign(socket, opened: id)}
  end

  # The diff's events, answered the way ReviewLive answers them but without
  # saving: new comments and status changes go back as threads_updated.
  def handle_event("create_comment", params, socket) do
    socket
    |> update(:threads, &DesignFixtures.add_comment(&1, params, socket.assigns.viewer))
    |> push_threads()
  end

  def handle_event("update_thread_status", %{"thread_id" => id, "status" => status}, socket) do
    socket
    |> update(:threads, &DesignFixtures.set_status(&1, id, status))
    |> push_threads()
  end

  def handle_event("toggle_hunk_diff", %{"hunk_id" => id}, socket) do
    {:noreply,
     update(socket, :expanded_hunk_ids, fn ids ->
       if MapSet.member?(ids, id), do: MapSet.delete(ids, id), else: MapSet.put(ids, id)
     end)}
  end

  def handle_event("mark_hunk_viewed", _params, socket),
    do: {:noreply, assign(socket, hunk_viewed: true)}

  def handle_event("mark_hunk_unviewed", _params, socket),
    do: {:noreply, assign(socket, hunk_viewed: false)}

  def handle_event("toggle_section_decision", %{"section_index" => index}, socket) do
    {:noreply, update_decision(socket, index, &%{&1 | editing: !&1.editing})}
  end

  # Selecting the current status again clears it, as on the review page.
  def handle_event("set_section_status", %{"section_index" => index, "status" => status}, socket) do
    {:noreply,
     update_decision(socket, index, fn decision ->
       %{
         decision
         | status: if(decision.status == status, do: "pending", else: status),
           editing: false
       }
     end)}
  end

  defp update_decision(socket, index, fun) do
    update(socket, :decisions, &Map.update!(&1, String.to_integer(index), fun))
  end

  defp push_threads(socket) do
    path = DesignFixtures.file_path()

    payload = %{
      threads:
        ReviewView.thread_payloads_for_file(%{published_threads: socket.assigns.threads}, path)
    }

    {:noreply, push_event(socket, "threads_updated:#{path}", payload)}
  end

  @impl true
  def render(%{live_action: :phone} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <style :type={ReviewsWeb.ColocatedCSS}>
        .dcp-shells {
          display: grid;
          gap: var(--space-7);
        }

        .dcp-shells figure,
        .dcp-decisions figure {
          display: grid;
          gap: var(--space-2);
          margin: 0;
          min-width: 0;
        }

        .dcp-shells figure > :first-child {
          border: var(--border-hair) solid var(--ds-line);
          border-radius: var(--radius-md);
        }

        /* Samples, not the page: no sticky bars, no full-height shell, and
           the topbar's viewport-based width fits the sample instead. */
        .dcp-shells :is(.l-topbar, .ds-shell-topbar) {
          position: static;
        }

        .dcp-shells .ds-shell {
          min-height: 0;
        }

        /* The sample frame draws the border. The bar rounds with it rather
           than painting square corners over it, and drops its own bottom
           border. Not overflow: hidden, which would clip the account menu. */
        .dcp-shells .ds-shell-topbar {
          border-bottom: 0;
          border-radius: inherit;
        }

        /* Each bar's backdrop blur makes it its own layer, so an open account
           menu would sit under the next sample. Lift the sample in use. */
        .dcp-shells figure {
          position: relative;
        }

        .dcp-shells figure:focus-within {
          z-index: 1;
        }

        .dcp-shells .l-wrap {
          width: auto;
          padding-inline: var(--space-7);
        }

        .dcp-decisions figure {
          justify-items: start;
        }

        .dcp-decisions {
          display: grid;
          gap: var(--space-7);
        }

        .dcp-frames {
          display: flex;
          flex-wrap: wrap;
          gap: var(--space-7);
        }

        .dcp-frames figure {
          display: grid;
          gap: var(--space-2);
          margin: 0;
          max-width: 100%;
        }

        .dcp-frames iframe {
          max-width: 100%;
          border: var(--border-hair) solid var(--ds-line-strong);
          border-radius: var(--radius-md);
          background: var(--ds-bg);
        }

        .dcp-phone {
          display: block;
          padding: var(--space-7);
        }

        .dcp-phone-guide {
          display: flex;
          flex-direction: column;
          align-items: flex-start;
          gap: var(--space-3);
          margin-bottom: var(--space-5);
        }

        [data-guide-flyout-toggle][aria-expanded="false"] + #dcp-guide-map {
          display: none;
        }

        .dcp-note {
          margin: 0;
          color: var(--ds-muted);
          font-size: var(--font-meta-size);
        }

        .dcp-skeleton {
          height: 14px;
          margin-bottom: var(--space-3);
          border-radius: var(--radius-xs);
          background: var(--ds-panel-raised);
        }

        /* One column up to 768px, as on the review page. */
        @media (max-width: 768px) {
          .dcp-rail {
            display: none;
          }
        }

        .dcp-skeleton:nth-child(3n) {
          width: 60%;
        }
      </style>
      <div id="design-phone" class="review-page dcp-phone">
        <div id="review-guide-shell" class="dcp-phone-guide">
          <button
            id="dcp-guide-toggle"
            type="button"
            class="ds-chip"
            data-guide-flyout-toggle
            aria-expanded="false"
            phx-click={JS.toggle_attribute({"aria-expanded", "true", "false"})}
          >
            Section map
          </button>
          <p id="dcp-guide-map" class="dcp-note">
            The Sections button opened the section map.
          </p>
        </div>
        <div class="review-workspace-content">
          <p :if={@opened} id="dcp-opened" class="dcp-note">
            The review page would open thread {@opened} here.
          </p>
          <div :for={n <- 1..14} :key={n} class="dcp-skeleton"></div>
        </div>
        <%!-- The decision button floats only inside a Guide with an outline. On the
        review page the Guide fills the first column and the decision sits in
        .review-packet-grid, the content column; the empty rail keeps that layout. --%>
        <div class="review-packet-shell has-outline">
          <div class="dcp-rail" aria-hidden="true"></div>
          <div class="review-packet-grid">
            <PacketComponents.packet_section_decision
              section={DesignFixtures.section(0, @decisions[0].status, "Retry once")}
              current_user={@viewer}
              can_decide
              editing={@decisions[0].editing}
            />
          </div>
        </div>
        <ActivityComponents.activity
          review={DesignFixtures.review()}
          threads={@threads}
          current_identity={nil}
          patchset_number={3}
        />
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="design-components" class="dc-page">
        <header>
          <DesignLive.catalog_nav current={:components} />
          <h1>Component playground</h1>
          <p class="dc-intro">
            The review page's components, from their real code with sample data.
            Reply, resolve and comment as much as you like: nothing is saved.
          </p>
        </header>

        <section id="dcp-shell" class="dc-section" aria-labelledby="dcp-shell-title">
          <h2 id="dcp-shell-title">App shell and navigation</h2>
          <ul class="dc-rules">
            <li>
              Home, the review list and Settings use <code>Layouts.landing_topbar</code>; the review
              page uses <code>ds_shell</code>. Signed in, Reviews links to the list.
            </li>
            <li>
              Both bars end in the one account control, <code>Layouts.account_menu</code>: signed in,
              the avatar and name open a menu with Settings and Sign out; signed out, a text-only
              Sign in. Sign-in buttons in the page body carry the GitHub mark.
            </li>
            <li>The shell follows the page theme, so these samples are not paired by theme.</li>
          </ul>
          <div class="dcp-shells">
            <figure>
              <Layouts.landing_topbar show_workflow_anchor={false} />
              <figcaption class="dc-name">landing_topbar, signed out</figcaption>
            </figure>
            <figure>
              <Layouts.landing_topbar
                current_user={@viewer}
                show_workflow_anchor={false}
                active={:reviews}
              />
              <figcaption class="dc-name">landing_topbar, signed in, on the review list</figcaption>
            </figure>
            <figure class="review-page">
              <.ds_shell brand="Reviews" home="#">
                <:actions>
                  <Layouts.account_menu current_user={@viewer} return_to="/design/components" />
                </:actions>
                <span></span>
              </.ds_shell>
              <figcaption class="dc-name">
                ds_shell, signed in: click the name for the menu
              </figcaption>
            </figure>
            <figure class="review-page">
              <.ds_shell brand="Reviews" home="#">
                <:actions>
                  <Layouts.account_menu return_to="/design/components" />
                </:actions>
                <span></span>
              </.ds_shell>
              <figcaption class="dc-name">ds_shell, signed out</figcaption>
            </figure>
          </div>
        </section>

        <DesignLive.catalog_section :let={theme} id="dcp-threads" title="Comment thread">
          <:rules>
            <li>The header names the line and its status. Resolve and Reopen sit on its right.</li>
            <li>Comments from the same person in a row share one name and avatar.</li>
            <li>A resolved thread folds to its count and last comment; View thread opens it.</li>
            <li>Reply opens a composer inside the thread. Escape or Cancel closes it.</li>
            <li>A verified agent's comment carries a Verified agent label with details.</li>
          </:rules>
          <div
            id={"dcp-threads-#{theme}"}
            phx-hook="DesignPlayground"
            phx-update="ignore"
            data-demo="threads"
            data-threads={@threads_json}
          >
          </div>
        </DesignLive.catalog_section>

        <DesignLive.catalog_section :let={theme} id="dcp-composer" title="Comment composer">
          <:rules>
            <li>Comment stays disabled until there is text. ⌘ Enter or Ctrl Enter posts.</li>
            <li>Escape and Cancel discard the draft.</li>
            <li>Touch screens get 16px text and no keyboard hint.</li>
            <li>Signed-out visitors see the sign-in prompt instead.</li>
          </:rules>
          <div
            id={"dcp-composer-#{theme}"}
            phx-hook="DesignPlayground"
            phx-update="ignore"
            data-demo="composer"
          >
          </div>
          <div
            id={"dcp-sign-in-#{theme}"}
            phx-hook="DesignPlayground"
            phx-update="ignore"
            data-demo="sign-in"
          >
          </div>
          <div
            id={"dcp-badges-#{theme}"}
            phx-hook="DesignPlayground"
            phx-update="ignore"
            data-demo="badges"
          >
          </div>
        </DesignLive.catalog_section>

        <section id="dcp-diff" class="dc-section" aria-labelledby="dcp-diff-title">
          <h2 id="dcp-diff-title">Diff and comments</h2>
          <ul class="dc-rules">
            <li>
              <code>PacketComponents.hunk_card</code>
              with the <code>DiffRenderer</code>
              hook: the same Pierre diff the review page renders, with the sample threads on it.
            </li>
            <li>
              Click a line number to comment. Resolve, reply, collapse and Viewed answer as on the
              review page, through <code>threads_updated</code>, but nothing is saved.
            </li>
            <li>Pierre follows the page theme, so the diff is not paired by theme.</li>
          </ul>
          <PacketComponents.hunk_card
            hunk={DesignFixtures.hunk(@hunk_viewed)}
            hunk_id={@hunk_id}
            file={DesignFixtures.file()}
            selected_patchset={%{number: 3}}
            published_threads={@threads}
            current_user={@viewer}
            diff_style="unified"
            expanded_hunk_ids={@expanded_hunk_ids}
          />
        </section>

        <DesignLive.catalog_section :let={theme} id="dcp-dialogs" title="Dialogs and menus">
          <:rules>
            <li>
              There is no shared dialog or menu component yet. These are the ones in use: the section
              decision panel here, the account menu above, the Comments log under Floating buttons,
              and the Guide map in the review page layouts.
            </li>
            <li>
              The section decision opens its controls in place. Selecting the current decision again
              clears it. On phones it is a floating button whose panel spans the screen, and Escape
              closes it.
            </li>
            <li>
              Someone who is not the owner sees a note instead of controls; signed out, a sign-in link.
            </li>
          </:rules>
          <div class="dcp-decisions">
            <%= for {index, _status, who} <- @decision_samples do %>
              <% index = if theme == "dark", do: index, else: index + 10 %>
              <figure>
                <PacketComponents.packet_section_decision
                  section={DesignFixtures.section(index, @decisions[index].status, "Retry once")}
                  current_user={if who != :signed_out, do: @viewer}
                  can_decide={who == :owner}
                  editing={@decisions[index].editing}
                  return_to="/design/components"
                />
                <figcaption class="dc-name">{decision_caption(who)}</figcaption>
              </figure>
            <% end %>
          </div>
        </DesignLive.catalog_section>

        <section id="dcp-floating" class="dc-section" aria-labelledby="dcp-floating-title">
          <h2 id="dcp-floating-title">Floating buttons</h2>
          <ul class="dc-rules">
            <li>
              Below 1200px the Comments button floats bottom right, above the code,
              with the unread count on its corner.
            </li>
            <li>
              On phones it is an icon button, with Sections above it when the Guide is open.
            </li>
            <li>A tap outside or Escape closes the open log. Mark all read clears the count.</li>
            <li>
              In a Guide with an outline the section decision floats at the bottom, and the other
              buttons stack above it.
            </li>
          </ul>
          <div class="dcp-frames">
            <figure>
              <iframe
                id="dcp-phone-frame"
                src={~p"/design/components/phone"}
                title="Floating buttons on a phone"
                width="390"
                height="720"
                loading="lazy"
              ></iframe>
              <figcaption class="dc-name">Phone, 390px</figcaption>
            </figure>
            <figure>
              <iframe
                id="dcp-tablet-frame"
                src={~p"/design/components/phone"}
                title="Floating buttons on a tablet"
                width="820"
                height="720"
                loading="lazy"
              ></iframe>
              <figcaption class="dc-name">Tablet, 820px</figcaption>
            </figure>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp decision_caption(:owner), do: "packet_section_decision, review owner"
  defp decision_caption(:reviewer), do: "packet_section_decision, another reviewer"
  defp decision_caption(:signed_out), do: "packet_section_decision, signed out"
end
