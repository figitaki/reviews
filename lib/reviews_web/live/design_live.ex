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

  tokens_css = File.read!(@tokens_path)

  # [{name, value}] for every token with this prefix, first definition wins
  # (the dark theme's, for colours).
  tokens = fn prefix ->
    ~r/^\s*(--#{prefix}[a-z0-9-]*):\s*([^;]+);/m
    |> Regex.scan(tokens_css, capture: :all_but_first)
    |> Enum.map(fn [name, value] -> {name, String.trim(value)} end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  @colors tokens.("ds-") |> Enum.map(&elem(&1, 0))
  @font_sizes (tokens.("font-size-") |> Enum.map(&elem(&1, 0))) -- ["--font-size-hero"]
  # Reading roles: --font-<role>-size with its -weight and -leading.
  @type_roles tokens.("font-")
              |> Enum.map(&elem(&1, 0))
              |> Enum.flat_map(fn name ->
                case Regex.run(~r/^--font-([a-z]+)-size$/, name) do
                  [_, role] when role != "size" -> [role]
                  _ -> []
                end
              end)
  @spaces tokens.("space-")
  @radii tokens.("radius-")
  @shadows tokens.("shadow-") |> Enum.map(&elem(&1, 0))

  # Icons used on controls, with the one thing each means.
  @icons [
    {"hero-check", "Allow, approve"},
    {"hero-x-mark", "Deny, clear, close"},
    {"hero-plus", "Create"},
    {"hero-key", "Token"},
    {"hero-no-symbol", "Revoke"},
    {"hero-link-slash", "Disconnect"},
    {"hero-arrow-right-start-on-rectangle", "Sign out"},
    {"hero-arrow-right", "Continue"},
    {"hero-chevron-left", "Newer, back"},
    {"hero-chevron-right", "Older, forward"},
    {"hero-arrow-uturn-left", "Back to the start"},
    {"hero-clipboard-document", "Copy"},
    {"hero-command-line", "CLI"},
    {"hero-book-open", "Demo, docs"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    unless enabled?(), do: raise(Disabled)

    {:ok,
     assign(socket,
       page_title: "Design catalog",
       colors: @colors,
       font_sizes: @font_sizes,
       button_variants: ~w(primary secondary ghost danger),
       button_states: ~w(default hover active focus disabled),
       type_roles: @type_roles,
       spaces: @spaces,
       radii: @radii,
       shadows: @shadows,
       icons: @icons
     )}
  end

  def enabled?, do: Application.get_env(:reviews, :design_catalog, false)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <style :type={ReviewsWeb.ColocatedCSS}>
        /* minmax(0, 1fr): a wide sample (the button matrix) scrolls inside
           its section instead of widening the page. */
        .dc-page {
          display: grid;
          grid-template-columns: minmax(0, 1fr);
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
          width: 2.25rem;
          height: 2.25rem;
          border: var(--border-hair) dashed var(--ds-line-strong);
          border-radius: var(--radius-lg);
        }

        .dc-box {
          width: 48px;
          height: 32px;
          border: var(--border-hair) solid var(--ds-line-strong);
          background: var(--ds-panel-raised);
        }

        /* max-width: at large text sizes on a phone the longest bars would
           widen the page. */
        .dc-bar {
          max-width: 100%;
          height: 12px;
          border-radius: var(--radius-xs);
          background: var(--ds-blue);
        }

        .dc-icons {
          display: grid;
          grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
          gap: var(--space-4) var(--space-3);
        }

        .dc-icon {
          display: grid;
          grid-template-columns: 20px minmax(0, 1fr);
          column-gap: var(--space-2);
          align-items: center;
        }

        .dc-icon-glyph {
          grid-row: span 2;
          width: 20px;
          height: 20px;
        }

        .dc-icon .dc-name {
          overflow-wrap: anywhere;
        }

        .dc-icon-meaning {
          color: var(--ds-muted);
          font-size: var(--font-meta-size);
        }

        /* Buttons with icons are wider than the default specimen column. */
        .dc-specimens.is-wide {
          grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
        }

        .dc-rules {
          display: grid;
          gap: var(--space-1);
          max-width: 72ch;
          margin: 0 0 var(--space-5);
          padding-left: var(--space-7);
          color: var(--ds-muted);
          font-size: var(--font-meta-size);
          line-height: var(--font-meta-leading);
          list-style: disc;
        }

        .dc-rules code {
          color: var(--ds-text);
          font-size: var(--font-size-2xs);
        }

        .dc-nav {
          display: flex;
          flex-wrap: wrap;
          gap: var(--space-3);
          margin-bottom: var(--space-5);
        }

        /* Specimens: a fixed-height stage so every sample shares one
           baseline, with its class name in a caption under it. */
        .dc-specimens {
          display: grid;
          grid-template-columns: repeat(auto-fill, minmax(112px, 1fr));
          gap: var(--space-5) var(--space-3);
        }

        .dc-stage {
          display: flex;
          align-items: center;
          min-height: 44px;
        }

        .dc-specimen {
          align-content: start;
        }

        .dc-specimen .dc-name {
          overflow-wrap: anywhere;
        }

        .dc-matrix {
          display: grid;
          grid-template-columns: 4rem repeat(4, max-content);
          align-items: center;
          gap: var(--space-4) var(--space-3);
          overflow-x: auto;
          /* Room for the focus ring, which overflow would clip. */
          padding: var(--space-1);
        }

        .dc-pair {
          display: flex;
          align-items: flex-end;
          gap: var(--space-3);
        }

        .dc-pair > .ds-field {
          flex: 1;
        }

        .dc-fields {
          display: grid;
          grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
          gap: var(--space-5);
        }

        .dc-role {
          display: grid;
          gap: var(--space-1);
        }

        .dc-scale {
          display: grid;
          grid-template-columns: minmax(0, 9.375rem) minmax(0, 1fr);
          align-items: center;
          gap: var(--space-2) var(--space-3);
        }

        /* Large type samples wrap instead of widening the panel. */
        .dc-scale > span {
          min-width: 0;
          overflow-wrap: anywhere;
        }

        .dc-elev {
          display: grid;
          place-items: center;
          width: 140px;
          height: 72px;
          margin: var(--space-5);
          border: var(--border-hair) solid var(--ds-line);
          border-radius: var(--radius-md);
          background: var(--ds-panel-raised);
        }

        /* .ds-empty-state caps its width; centre it in the sample panel. */
        .dc-theme > .ds-empty-state {
          width: 100%;
          justify-self: center;
        }

        @media (max-width: 768px) {
          .dc-themes {
            grid-template-columns: minmax(0, 1fr);
          }
        }
      </style>

      <div id="design-catalog" class="dc-page">
        <header>
          <.catalog_nav current={:tokens} />
          <h1>Design catalog</h1>
          <p class="dc-intro">
            Tokens from <code>tokens.css</code> and the <code>ds_</code> components,
            in both themes. Change a token or component and check it here first.
          </p>
        </header>

        <.catalog_section id="dc-pills" title="Pills in use">
          <:rules>
            <li>
              <code>&lt;.ds_chip&gt;</code>
              is for filters and toggles: links with a 44px tap target on touch.
            </li>
            <li>
              Open decision: revisions still use their own rounded-square chip. The visual
              audit recommends the <code>ds_chip</code> pill with a filled selection.
            </li>
          </:rules>
          <div class="dc-specimens">
            <.specimen name="<.ds_chip>">
              <.ds_chip patch="#">All</.ds_chip>
            </.specimen>
            <.specimen name="<.ds_chip selected>">
              <.ds_chip patch="#" selected>Mine</.ds_chip>
            </.specimen>
            <.specimen name=".ds-badge"><span class="ds-badge">1 open</span></.specimen>
            <.specimen name=".review-revision-chip">
              <span class="review-revision-chip">v2</span>
            </.specimen>
            <.specimen name=".review-revision-chip.is-active">
              <span class="review-revision-chip is-active">v3</span>
            </.specimen>
            <.specimen :for={count <- ["4", "12", "99+"]} :key={count} name=".review-activity-count">
              <span class="dc-anchor"><span class="review-activity-count">{count}</span></span>
            </.specimen>
          </div>
        </.catalog_section>

        <.catalog_section id="dc-avatars" title="Identity avatars">
          <:rules>
            <li>
              <code>&lt;.ds_avatar_mark&gt;</code>
              shows a person's GitHub avatar or an agent's provider logo, else the first letter of
              its name. It is decorative: put the name in text beside it.
            </li>
          </:rules>
          <div class="dc-specimens">
            <.specimen name="<.ds_avatar_mark> agent logo">
              <.ds_avatar_mark identity={
                %{avatar_url: ~p"/images/connectors/claude.png", display_name: "Claude"}
              } />
            </.specimen>
            <.specimen name="<.ds_avatar_mark> no image">
              <.ds_avatar_mark identity={%{avatar_url: nil, display_name: "Carey"}} />
            </.specimen>
          </div>
        </.catalog_section>

        <.catalog_section id="dc-buttons" title="Buttons">
          <:rules>
            <li>
              Every button is <code>&lt;.ds_button&gt;</code>. Pass <code>navigate</code>,
              <code>patch</code>
              or <code>href</code>
              for a link that looks the same.
            </li>
            <li>
              Primary is the one main action in a view. Secondary is everything else. Ghost is for
              low-emphasis actions inside panels. Danger is for actions that delete or revoke.
            </li>
            <li>
              Sizes: <code>sm</code>
              28px in dense rows, <code>md</code>
              32px in toolbars and panels, <code>lg</code>
              40px in forms and page calls to action, the same height as a field.
            </li>
            <li>
              Hover and press change the surface only; nothing moves. Primary stays inverted.
            </li>
            <li>Keyboard focus draws a 2px <code>--ds-focus</code> ring, 2px outside the edge.</li>
            <li>
              Disabled dims to 38% and ignores clicks. Say nearby why it is disabled.
            </li>
            <li>On touch screens every size has a 44px tap target without growing.</li>
            <li>
              Labels centre on their letters: <code>.ds-label</code>
              trims the label to cap height and baseline. Put it on the label element of any
              other flex control; bare text in a flex box cannot be trimmed.
            </li>
          </:rules>
          <div class="dc-matrix" role="table" aria-label="Button states">
            <span></span>
            <span :for={variant <- @button_variants} :key={variant} class="dc-name">
              {variant}
            </span>
            <%= for state <- @button_states do %>
              <span class="dc-name">{state}</span>
              <span :for={variant <- @button_variants} :key={variant}>
                <.ds_button
                  variant={variant}
                  disabled={state == "disabled"}
                  data-state={state not in ~w(default disabled) && state}
                  tabindex="-1"
                >
                  {String.capitalize(variant)}
                </.ds_button>
              </span>
            <% end %>
          </div>
          <div class="dc-specimens">
            <.specimen :for={size <- ~w(sm md lg)} :key={size} name={"size=#{size}"}>
              <.ds_button size={size}>Button</.ds_button>
            </.specimen>
            <.specimen name="navigate=…">
              <.ds_button navigate="#" variant="primary">Link</.ds_button>
            </.specimen>
          </div>
        </.catalog_section>

        <.catalog_section id="dc-icons" title="Icons">
          <:rules>
            <li>
              Icons are Heroicons outline, through <code>&lt;.icon name="hero-…"&gt;</code>. They
              take the text colour and are hidden from screen readers; the label says what the
              control does.
            </li>
            <li>
              Put an icon on a button with <code>icon="hero-…"</code>. Use one when it makes the
              action quicker to find: confirm, deny, add, copy, revoke, move between pages. Leave
              plain text buttons alone when no icon fits.
            </li>
            <li>One meaning per icon. Reuse the names below before adding a new one.</li>
            <li>
              Sign in with GitHub always uses <code>&lt;.ds_github_button&gt;</code>, which shows
              the GitHub mark. Keep the mark unchanged and in one colour with high contrast, as
              GitHub's brand rules ask. The top bar's primary Sign in stays text only.
            </li>
          </:rules>
          <div class="dc-icons">
            <div :for={{name, meaning} <- @icons} :key={name} class="dc-icon">
              <.icon name={name} class="dc-icon-glyph" />
              <span class="dc-name">{name}</span>
              <span class="dc-icon-meaning">{meaning}</span>
            </div>
            <div class="dc-icon">
              <.github_mark class="dc-icon-glyph" />
              <span class="dc-name">&lt;.github_mark&gt;</span>
              <span class="dc-icon-meaning">GitHub sign-in only</span>
            </div>
          </div>
          <div class="dc-specimens is-wide">
            <.specimen name="<.ds_github_button>">
              <.ds_github_button href="#" />
            </.specimen>
            <.specimen name={~s(variant="secondary" size="sm")}>
              <.ds_github_button href="#" variant="secondary" size="sm">Sign in</.ds_github_button>
            </.specimen>
            <.specimen name={~s(icon="hero-check")}>
              <.ds_button variant="primary" icon="hero-check">Allow</.ds_button>
            </.specimen>
            <.specimen name={~s(icon="hero-no-symbol")}>
              <.ds_button variant="danger" size="sm" icon="hero-no-symbol">Revoke</.ds_button>
            </.specimen>
          </div>
        </.catalog_section>

        <.catalog_section :let={theme} id="dc-fields" title="Fields">
          <:rules>
            <li>
              Every field is <code>&lt;.input&gt;</code>. It renders the label, the control and any
              errors, and styles text, textarea and select the same way.
            </li>
            <li>A visible label sits above every field. A placeholder is an example, not a label.</li>
            <li>Focus turns the border <code>--ds-focus</code> with a soft ring.</li>
            <li>
              An error turns the border red, sets <code>aria-invalid</code>, and says under the field
              what to do.
            </li>
            <li>Disabled and read-only fields have a dashed border and no fill.</li>
            <li>
              Fields are 40px with 14px text, and 16px text on touch screens so iOS does not zoom in.
            </li>
            <li>Put a <code>size="lg"</code> button next to a field.</li>
          </:rules>
          <div class="dc-fields">
            <.input
              id={"dc-field-#{theme}"}
              name="handle"
              label="Handle"
              value=""
              placeholder="claude"
            />
            <.input
              id={"dc-field-focus-#{theme}"}
              name="focus"
              label="Focused"
              value="carey"
              data-state="focus"
            />
            <.input
              id={"dc-field-error-#{theme}"}
              name="taken"
              label="With an error"
              value="carey"
              errors={["That handle is taken. Pick another."]}
            />
            <.input
              id={"dc-field-disabled-#{theme}"}
              name="disabled"
              label="Disabled"
              value="figitaki"
              disabled
            />
            <.input
              id={"dc-field-select-#{theme}"}
              name="identity"
              type="select"
              label="Select"
              value="carey"
              options={["Carey (you)": "carey", "Claude (agent)": "claude"]}
            />
            <.input
              id={"dc-field-textarea-#{theme}"}
              name="body"
              type="textarea"
              label="Textarea"
              value=""
              placeholder="Leave a comment…"
            />
          </div>
          <form class="dc-pair" onsubmit="return false">
            <.input
              id={"dc-pair-#{theme}"}
              name="token"
              label="Token name"
              value=""
              placeholder="laptop"
            />
            <.ds_button type="submit" variant="primary" size="lg">Generate token</.ds_button>
          </form>
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
          <:rules>
            <li>
              Use a role, which sets size, weight and leading together. The sizes below them are the ladder the roles pick from.
            </li>
          </:rules>
          <div
            :for={role <- @type_roles}
            :key={role}
            class="dc-role"
            style={"font-size: var(--font-#{role}-size); font-weight: var(--font-#{role}-weight, 400); line-height: var(--font-#{role}-leading, 1.4);#{role == "code" && " font-family: var(--font-mono);"}"}
          >
            <span>Review any diff, one section at a time.</span>
            <span class="dc-name">--font-{role}-*</span>
          </div>
          <div class="dc-scale">
            <%= for name <- @font_sizes do %>
              <span class="dc-name">{name}</span>
              <span style={"font-size: var(#{name})"}>Review any diff.</span>
            <% end %>
          </div>
        </.catalog_section>

        <.catalog_section id="dc-space" title="Space, radius, shadow">
          <div class="dc-scale">
            <%= for {name, value} <- @spaces do %>
              <span class="dc-name">{name} {value}</span>
              <span class="dc-bar" style={"width: var(#{name})"}></span>
            <% end %>
          </div>
          <div class="dc-specimens">
            <.specimen :for={{name, value} <- @radii} :key={name} name={"#{name} #{value}"}>
              <span class="dc-box" style={"border-radius: var(#{name})"}></span>
            </.specimen>
          </div>
          <div class="dc-row">
            <div
              :for={name <- @shadows}
              :key={name}
              class="dc-elev"
              style={"box-shadow: var(#{name})"}
            >
              <span class="dc-name">{name}</span>
            </div>
          </div>
        </.catalog_section>
      </div>
    </Layouts.app>
    """
  end

  attr :current, :atom, required: true

  @doc "Links between the catalog's pages."
  def catalog_nav(assigns) do
    ~H"""
    <nav class="dc-nav" aria-label="Design catalog">
      <.ds_chip navigate={~p"/design"} selected={@current == :tokens}>Tokens and parts</.ds_chip>
      <.ds_chip navigate={~p"/design/components"} selected={@current == :components}>
        Components
      </.ds_chip>
      <.ds_chip navigate={~p"/design/layouts"} selected={@current == :layouts}>
        Page layouts
      </.ds_chip>
    </nav>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  slot :rules, doc: "How the parts behave, as <li> items, shown once above both themes."
  slot :inner_block, required: true, doc: "Rendered once per theme, with the theme name."

  @doc "A section rendered side by side in the dark and the light theme."
  def catalog_section(assigns) do
    ~H"""
    <section id={@id} class="dc-section" aria-labelledby={"#{@id}-title"}>
      <h2 id={"#{@id}-title"}>{@title}</h2>
      <ul :if={@rules != []} class="dc-rules">{render_slot(@rules)}</ul>
      <div class="dc-themes">
        <div :for={theme <- ~w(dark light)} :key={theme} class="dc-theme" data-theme={theme}>
          <p class="dc-theme-name">{theme}</p>
          {render_slot(@inner_block, theme)}
        </div>
      </div>
    </section>
    """
  end

  attr :name, :string, required: true
  slot :inner_block, required: true

  defp specimen(assigns) do
    ~H"""
    <div class="dc-specimen dc-item">
      <div class="dc-stage">{render_slot(@inner_block)}</div>
      <span class="dc-name">{@name}</span>
    </div>
    """
  end
end
