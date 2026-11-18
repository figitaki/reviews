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

  alias ReviewsWeb.{DesignFixtures, DesignLive}
  alias ReviewsWeb.ReviewLive.ActivityComponents

  @impl true
  def mount(_params, _session, socket) do
    unless DesignLive.enabled?(), do: raise(DesignLive.Disabled)

    threads = DesignFixtures.threads()

    {:ok,
     assign(socket,
       page_title: "Component playground",
       threads: threads,
       threads_json:
         JSON.encode!(
           Reviews.ReviewView.thread_payloads_for_file(
             %{published_threads: threads},
             DesignFixtures.file_path()
           )
         ),
       opened: nil
     )}
  end

  # The Comments log asks the review page to open a thread; say which.
  @impl true
  def handle_event("open_activity_thread", %{"thread_id" => id}, socket) do
    {:noreply, assign(socket, opened: id)}
  end

  @impl true
  def render(%{live_action: :phone} = assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <style :type={ReviewsWeb.ColocatedCSS}>
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
end
