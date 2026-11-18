defmodule ReviewsWeb.DesignLayoutsLive do
  @moduledoc """
  `/design/layouts`: the review list, a review and Settings, framed at
  desktop and phone widths side by side.

  The frames load the real pages, so they show what you would see there:
  signed out, the list and Settings show their sign-in states. The review
  frame opens the demo review (`Reviews.DemoReview`), which is seeded in dev
  and on previews.

  On and off with `/design` (`ReviewsWeb.DesignLive.enabled?/0`).
  """
  use ReviewsWeb, :live_view

  alias ReviewsWeb.DesignLive

  @impl true
  def mount(_params, _session, socket) do
    unless DesignLive.enabled?(), do: raise(DesignLive.Disabled)

    {:ok,
     assign(socket,
       page_title: "Page layouts",
       pages: [
         %{
           id: "list",
           title: "Review list",
           path: ~p"/reviews",
           note: "Compact header, one search field, a chip row that scrolls on phones."
         },
         %{
           id: "review",
           title: "Review",
           path: ~p"/r/#{Reviews.DemoReview.slug()}",
           note:
             "Guide beside the code on wide screens. On phones: the Guide map flyout, and the " <>
               "floating Sections, Comments and decision buttons."
         },
         %{
           id: "settings",
           title: "Settings",
           path: ~p"/settings",
           note: "Stacked cards of forms; fields and buttons share one height."
         }
       ]
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <style :type={ReviewsWeb.ColocatedCSS}>
        .dcl-page {
          display: grid;
          gap: var(--space-5);
        }

        .dcl-frames {
          display: flex;
          flex-wrap: wrap;
          align-items: flex-start;
          gap: var(--space-7);
        }

        .dcl-frames figure {
          display: grid;
          gap: var(--space-2);
          margin: 0;
        }

        .dcl-viewport {
          overflow: hidden;
          border: var(--border-hair) solid var(--ds-line-strong);
          border-radius: var(--radius-md);
          background: var(--ds-bg);
        }

        /* Desktop: a 1280 x 800 page shown at half size. */
        .dcl-viewport.is-desktop {
          width: 640px;
          height: 400px;
        }

        .dcl-viewport.is-desktop iframe {
          width: 1280px;
          height: 800px;
          transform: scale(0.5);
          transform-origin: 0 0;
        }

        .dcl-viewport.is-phone {
          width: 293px;
          height: 633px;
        }

        /* Phone: 390 x 844 at three quarters. */
        .dcl-viewport.is-phone iframe {
          width: 390px;
          height: 844px;
          transform: scale(0.75);
          transform-origin: 0 0;
        }

        .dcl-viewport iframe {
          display: block;
          border: 0;
        }
      </style>

      <div id="design-layouts" class="dc-page">
        <header>
          <DesignLive.catalog_nav current={:layouts} />
          <h1>Page layouts</h1>
          <p class="dc-intro">
            The real pages, framed at desktop (1280px, shown at half size) and phone (390px)
            widths. They show what you would see there, signed in or not; open one to use it.
          </p>
        </header>

        <section
          :for={page <- @pages}
          :key={page.id}
          id={"dcl-#{page.id}"}
          class="dc-section dcl-page"
          aria-labelledby={"dcl-#{page.id}-title"}
        >
          <h2 id={"dcl-#{page.id}-title"}>{page.title}</h2>
          <p class="dc-intro">
            {page.note} <.link href={page.path}>Open {page.path}</.link>
          </p>
          <div class="dcl-frames">
            <figure>
              <div class="dcl-viewport is-desktop">
                <iframe
                  id={"dcl-#{page.id}-desktop"}
                  src={page.path}
                  title={"#{page.title} at desktop width"}
                  loading="lazy"
                  tabindex="-1"
                ></iframe>
              </div>
              <figcaption class="dc-name">Desktop, 1280px</figcaption>
            </figure>
            <figure>
              <div class="dcl-viewport is-phone">
                <iframe
                  id={"dcl-#{page.id}-phone"}
                  src={page.path}
                  title={"#{page.title} at phone width"}
                  loading="lazy"
                ></iframe>
              </div>
              <figcaption class="dc-name">Phone, 390px</figcaption>
            </figure>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
