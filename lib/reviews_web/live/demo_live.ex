defmodule ReviewsWeb.DemoLive do
  use ReviewsWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    user =
      case session["current_user_id"] do
        id when is_integer(id) -> Reviews.Repo.get(Reviews.Accounts.User, id)
        _ -> nil
      end

    scenarios =
      Enum.map(Reviews.DemoCatalog.scenarios(), fn scenario ->
        Map.put(scenario, :available?, Reviews.Reviews.get_review_by_slug(scenario.slug) != nil)
      end)

    {:ok,
     socket
     |> assign(:page_title, "Demo & QA")
     |> assign(:current_user, user)
     |> stream(:scenarios, scenarios)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} chrome={false}>
      <Layouts.landing_topbar current_user={@current_user} show_workflow_anchor={false} />
      <main id="demo-hub" class="demo-hub">
        <header class="demo-intro">
          <p class="l-eyebrow">Explore Reviews</p>
          <h1>Demo &amp; QA</h1>
          <p>
            Real reviews, ready to explore. Compare documents, follow a discussion, and try the review workflow.
          </p>
          <p class="demo-note">
            Browse without an account. Sign in to comment and record decisions. These are shared samples; your comments are visible to other visitors.
          </p>
        </header>
        <div id="demo-checklist">
          <div
            id="demo-checklist-controls"
            class="demo-checklist-header"
            phx-hook="DemoChecklist"
            phx-update="ignore"
          >
            <p id="demo-progress" role="status" aria-live="polite">Check off what you have tried.</p>
            <button id="demo-reset-checks" type="button" class="review-button review-button-ghost">Reset checklist</button>
          </div>
          <div id="demo-scenarios" phx-update="stream" class="demo-grid">
            <article :for={{id, scenario} <- @streams.scenarios} id={id} class="demo-card">
              <h2>{scenario.title}</h2>
              <p>{scenario.description}</p>
              <.link
                :if={scenario.available?}
                id={"demo-open-#{scenario.id}"}
                navigate={~p"/r/#{scenario.slug}"}
                class="review-button review-button-primary"
              >
                Open sample <.icon name="hero-arrow-right" class="size-4" />
              </.link>
              <p :if={!scenario.available?} class="demo-note">
                This sample has not been installed on this server yet.
              </p>
              <fieldset>
                <legend>Try it / QA checklist</legend>
                <.input
                  :for={{check, index} <- Enum.with_index(scenario.checks)}
                  type="checkbox"
                  id={"demo-check-#{scenario.id}-#{index}"}
                  name={"#{scenario.id}-#{index}"}
                  label={check}
                  checked={false}
                  data-demo-check
                />
              </fieldset>
            </article>
          </div>
          <section class="demo-card demo-crosschecks" aria-labelledby="demo-crosschecks-title">
            <h2 id="demo-crosschecks-title">Across every review</h2>
            <p>
              Use these checks when validating a release. Checkmarks are saved only in this browser.
            </p>
            <.input
              type="checkbox"
              id="demo-check-theme"
              name="theme"
              label="Try light, dark, and system themes"
              checked={false}
              data-demo-check
            />
            <.input
              type="checkbox"
              id="demo-check-keyboard"
              name="keyboard"
              label="Navigate with Tab, Enter, and Space; check visible focus"
              checked={false}
              data-demo-check
            />
            <.input
              type="checkbox"
              id="demo-check-mobile"
              name="mobile"
              label="Use a narrow screen and check navigation and scrolling"
              checked={false}
              data-demo-check
            />
            <.input
              type="checkbox"
              id="demo-check-sharing"
              name="sharing"
              label="Open a sample link in a signed-out window"
              checked={false}
              data-demo-check
            />
            <.input
              type="checkbox"
              id="demo-check-account"
              name="account"
              label="Sign in and try account settings and agent identities"
              checked={false}
              data-demo-check
            />
            <.link navigate={~p"/settings"} class="review-button review-button-ghost">Account settings</.link>
            <p class="demo-note">
              CLI and API checks require a token from Settings: push a new review, append a revision, and read its comments. Use your own review for these checks.
            </p>
          </section>
        </div>
      </main>
    </Layouts.app>
    """
  end
end
