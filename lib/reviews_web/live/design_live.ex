defmodule ReviewsWeb.DesignLive do
  @moduledoc """
  `/design`: a catalog of the design system, rendered from the real tokens
  and components so differences show up side by side.

  Every section renders twice, in the dark and the light theme. Token names
  are read from `assets/css/tokens.css` at compile time, so a new token
  shows up here without editing this file.

  On in dev and test, and on preview apps (`DESIGN_CATALOG=true` in
  `fly.preview.toml`). Production leaves it off and the route returns 404.
  """
  use ReviewsWeb, :live_view

  defmodule Disabled do
    @moduledoc false
    defexception message: "the design catalog is off", plug_status: 404
  end

  @tokens_path Path.expand("../../../assets/css/tokens.css", __DIR__)
  @external_resource @tokens_path

  token_names = fn prefix ->
    ~r/^\s*(--#{prefix}[a-z0-9-]*):/m
    |> Regex.scan(File.read!(@tokens_path), capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  @colors token_names.("ds-")
  @font_sizes token_names.("font-size-") -- ["--font-size-hero"]
  @spaces token_names.("space-")
  @radii token_names.("radius-")
  @shadows token_names.("shadow-")

  @impl true
  def mount(_params, _session, socket) do
    unless enabled?(), do: raise(Disabled)

    {:ok,
     assign(socket,
       page_title: "Design catalog",
       colors: @colors,
       font_sizes: @font_sizes,
       spaces: @spaces,
       radii: @radii,
       shadows: @shadows
     )}
  end

  def enabled?, do: Application.get_env(:reviews, :design_catalog, false)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <style :type={ReviewsWeb.ColocatedCSS}>
        .dc-page {
          display: grid;
          gap: var(--space-10);
          width: min(1200px, 100%);
          margin: 0 auto;
          padding: var(--space-10) var(--space-7) var(--space-14);
          color: var(--ds-text);
          font-family: var(--font-sans);
        }

        .dc-page h1 {
          margin: 0;
          font-size: var(--font-section-size);
          font-weight: var(--font-section-weight);
        }

        .dc-intro {
          margin: var(--space-2) 0 0;
          color: var(--ds-muted);
          font-size: var(--font-meta-size);
        }

        .dc-section > h2 {
          margin: 0 0 var(--space-3);
          font-size: var(--font-subheading-size);
          font-weight: var(--font-subheading-weight);
        }

        .dc-themes {
          display: grid;
          grid-template-columns: repeat(2, minmax(0, 1fr));
          gap: var(--space-5);
        }

        .dc-theme {
          display: grid;
          align-content: start;
          gap: var(--space-5);
          min-width: 0;
          border: var(--border-hair) solid var(--ds-line);
          border-radius: var(--radius-md);
          background: var(--ds-bg);
          color: var(--ds-text);
          padding: var(--space-7);
        }

        .dc-theme-name {
          margin: 0;
          color: var(--ds-faint);
          font-size: var(--font-size-2xs);
          font-weight: var(--weight-semi);
          letter-spacing: var(--tracking-eyebrow);
          text-transform: uppercase;
        }

        .dc-row {
          display: flex;
          flex-wrap: wrap;
          align-items: center;
          gap: var(--space-3);
        }

        .dc-item {
          display: grid;
          justify-items: start;
          gap: var(--space-2);
        }

        .dc-name {
          color: var(--ds-muted);
          font-family: var(--font-mono);
          font-size: var(--font-size-2xs);
        }

        .dc-swatches {
          display: grid;
          grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
          gap: var(--space-3);
        }

        .dc-swatch {
          display: flex;
          align-items: center;
          gap: var(--space-3);
          min-width: 0;
        }

        .dc-swatch > span:first-child {
          flex-shrink: 0;
          width: 28px;
          height: 28px;
          border: var(--border-hair) solid var(--ds-line-strong);
          border-radius: var(--radius-sm);
        }

        /* .ds-card has a settings-page min-height; samples do not need it. */
        .dc-theme .ds-card {
          min-height: 0;
        }

        /* .review-activity-count sits on the corner of the Comments button. */
        .dc-anchor {
          position: relative;
          display: inline-block;
          width: 36px;
          height: 36px;
          border: var(--border-hair) dashed var(--ds-line-strong);
          border-radius: var(--radius-lg);
        }

        .dc-box {
          width: 48px;
          height: 32px;
          border: var(--border-hair) solid var(--ds-line-strong);
          background: var(--ds-panel-raised);
        }

        .dc-bar {
          height: 12px;
          border-radius: var(--radius-xs);
          background: var(--ds-blue);
        }

        @media (max-width: 768px) {
          .dc-themes {
            grid-template-columns: minmax(0, 1fr);
          }
        }
      </style>

      <div id="design-catalog" class="dc-page">
        <header>
          <h1>Design catalog</h1>
          <p class="dc-intro">
            Tokens from <code>tokens.css</code> and the <code>ds_</code> components,
            in both themes. Change a token or component and check it here first.
          </p>
        </header>

        <.catalog_section id="dc-pills" title="Pills in use">
          <div class="dc-row">
            <.sample name="<.ds_chip>">
              <.ds_chip patch="#">All</.ds_chip>
            </.sample>
            <.sample name="<.ds_chip selected>">
              <.ds_chip patch="#" selected>Mine</.ds_chip>
            </.sample>
            <.sample name=".ds-badge">
              <span class="ds-badge">1 open</span>
            </.sample>
            <.sample name=".review-revision-chip">
              <span class="review-revision-chip">v2</span>
            </.sample>
            <.sample name=".review-revision-chip.is-active">
              <span class="review-revision-chip is-active">v3</span>
            </.sample>
            <.sample name=".review-activity-count">
              <span class="dc-anchor"><span class="review-activity-count">4</span></span>
            </.sample>
          </div>
        </.catalog_section>

        <.catalog_section id="dc-buttons" title="Buttons and fields">
          <div class="dc-row">
            <.ds_button variant="primary">Primary</.ds_button>
            <.ds_button>Secondary</.ds_button>
            <.ds_button variant="ghost">Ghost</.ds_button>
            <.ds_button variant="danger">Danger</.ds_button>
            <.ds_button disabled>Disabled</.ds_button>
          </div>
          <input class="ds-input" type="text" placeholder=".ds-input" aria-label="Sample field" />
        </.catalog_section>

        <.catalog_section id="dc-states" title="Cards and empty states">
          <.ds_card>
            <h3>.ds-card</h3>
            <p class="dc-intro">Flat panel with a hairline border.</p>
          </.ds_card>
          <.ds_empty_state
            icon="hero-inbox"
            title="<.ds_empty_state>"
            body="Says what happened and what to do next."
          >
            <:actions>
              <.ds_button>Action</.ds_button>
            </:actions>
          </.ds_empty_state>
        </.catalog_section>

        <.catalog_section id="dc-colors" title="Colour">
          <div class="dc-swatches">
            <div :for={name <- @colors} :key={name} class="dc-swatch">
              <span style={"background: var(#{name})"}></span>
              <span class="dc-name">{name}</span>
            </div>
          </div>
        </.catalog_section>

        <.catalog_section id="dc-type" title="Type">
          <div
            :for={name <- @font_sizes}
            :key={name}
            class="dc-item"
            style={"font-size: var(#{name})"}
          >
            <span>Review any diff.</span>
            <span class="dc-name">{name}</span>
          </div>
        </.catalog_section>

        <.catalog_section id="dc-space" title="Space, radius, shadow">
          <div class="dc-item">
            <div :for={name <- @spaces} :key={name} class="dc-row">
              <span class="dc-bar" style={"width: var(#{name})"}></span>
              <span class="dc-name">{name}</span>
            </div>
          </div>
          <div class="dc-row">
            <.sample :for={name <- @radii} :key={name} name={name}>
              <span class="dc-box" style={"border-radius: var(#{name})"}></span>
            </.sample>
          </div>
          <div class="dc-row">
            <.sample :for={name <- @shadows} :key={name} name={name}>
              <span class="dc-box" style={"box-shadow: var(#{name})"}></span>
            </.sample>
          </div>
        </.catalog_section>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp catalog_section(assigns) do
    ~H"""
    <section id={@id} class="dc-section" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"}>{@title}</h2>
      <div class="dc-themes">
        <div :for={theme <- ~w(dark light)} :key={theme} class="dc-theme" data-theme={theme}>
          <p class="dc-theme-name">{theme}</p>
          {render_slot(@inner_block)}
        </div>
      </div>
    </section>
    """
  end

  attr :name, :string, required: true
  slot :inner_block, required: true

  defp sample(assigns) do
    ~H"""
    <div class="dc-item">
      {render_slot(@inner_block)}
      <span class="dc-name">{@name}</span>
    </div>
    """
  end
end
