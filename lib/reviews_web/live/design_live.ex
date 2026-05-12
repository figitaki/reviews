defmodule ReviewsWeb.DesignLive do
  @moduledoc """
  Development-only playground for the product design system.
  """
  use ReviewsWeb, :live_view

  alias Reviews.DesignSystem

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Design System")
     |> assign(:colors, DesignSystem.colors())
     |> assign(:type_scale, DesignSystem.type_scale())
     |> assign(:spacing, DesignSystem.spacing())
     |> assign(:icons, DesignSystem.icons())
     |> assign(:molecules, DesignSystem.molecules())
     |> assign(:compounds, DesignSystem.compounds())
     |> assign(:organisms, DesignSystem.organisms())
     |> assign(:files, DesignSystem.sample_files())
     |> assign(:diff_rows, DesignSystem.sample_diff_rows())
     |> assign(:states, DesignSystem.states())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} chrome={false}>
      <main id="design-system-playground" class="design-page">
        <.ds_shell brand="Reviews" home={~p"/"}>
          <:nav>
            <.ds_nav_item navigate="/design" active>System</.ds_nav_item>
            <.ds_nav_item navigate={~p"/r/uzRiKvyr"}>Review</.ds_nav_item>
            <.ds_nav_item navigate={~p"/settings"}>Settings</.ds_nav_item>
          </:nav>
          <:actions>
            <Layouts.theme_toggle />
          </:actions>

          <div class="design-main">
            <.ds_page_header
              eyebrow="Product system"
              title="Atoms to organisms for code review."
              description="A focused catalog for the Reviews interface: raw tokens, small controls, composed surfaces, and full review workflows. The visual language stays compact, dark, and code-first."
            >
              <:actions>
                <.ds_button variant="primary">
                  <.icon name="hero-check" class="size-4" /> Publish
                </.ds_button>
              </:actions>
            </.ds_page_header>

            <nav class="design-nav" aria-label="Design system sections">
              <a href="#overview">Overview</a>
              <a href="#atoms">Atoms</a>
              <a href="#molecules">Molecules</a>
              <a href="#compounds">Compounds</a>
              <a href="#organisms">Organisms</a>
            </nav>

            <.ds_section
              id="overview"
              eyebrow="Overview"
              title="The system scales from tokens to full review views."
              description="Each level should stay small enough to reason about on its own, then compose upward without changing behavior or tone."
            >
              <div class="design-section-body">
                <div class="design-taxonomy">
                  <article :for={level <- taxonomy_levels()} class="design-taxonomy-card">
                    <span>{level.index}</span>
                    <h3>{level.name}</h3>
                    <p>{level.body}</p>
                  </article>
                </div>
              </div>
            </.ds_section>

            <.ds_section
              id="atoms"
              eyebrow="Atoms"
              title="Color, type, spacing, and icons are the raw material."
              description="Atoms should be boring and dependable. They define the review surface before any component decisions happen."
            >
              <div class="design-section-body">
                <div class="design-atom-grid">
                  <.ds_card>
                    <h3>Color</h3>
                    <div class="design-token-list">
                      <.ds_token
                        :for={color <- @colors}
                        label={color.name}
                        value={color.value}
                        role={color.role}
                      />
                    </div>
                  </.ds_card>

                  <.ds_card>
                    <h3>Type</h3>
                    <div class="design-type-list">
                      <div
                        :for={type <- @type_scale}
                        class={"design-type-row is-#{String.downcase(type.name)}"}
                      >
                        <p>{type.sample}</p>
                        <span>{type.name} · {type.size} · {type.role}</span>
                      </div>
                    </div>
                  </.ds_card>

                  <.ds_card>
                    <h3>Spacing</h3>
                    <div class="design-space-list">
                      <span :for={space <- @spacing}>
                        <i style={"width: #{space.value}"}></i>
                        <strong>{space.value}</strong>
                        <em>{space.role}</em>
                      </span>
                    </div>
                  </.ds_card>

                  <.ds_card>
                    <h3>Icons</h3>
                    <p class="design-card-note">
                      Use Phoenix's local <code class="ds-code">&lt;.icon&gt;</code>
                      component with Heroicons names. Icons stay compact, neutral, and paired with text unless the action is universally clear.
                    </p>
                    <div class="design-icon-list">
                      <div :for={icon <- @icons} class="design-icon-row">
                        <span><.ds_catalog_icon name={icon.icon} /></span>
                        <div>
                          <strong>{icon.name}</strong>
                          <p>{icon.role}</p>
                        </div>
                      </div>
                    </div>
                  </.ds_card>
                </div>
              </div>
            </.ds_section>

            <.ds_section
              id="molecules"
              eyebrow="Molecules"
              title="Small controls with one job each."
              description="Molecules combine atoms into focused controls. They are compact, keyboard-visible, and predictable in review workflows."
            >
              <div class="design-section-body">
                <div class="design-molecule-layout">
                  <aside class="design-spec-list" aria-label="Molecule inventory">
                    <div :for={molecule <- @molecules}>
                      <strong>{molecule.name}</strong>
                      <span>{molecule.role}</span>
                    </div>
                  </aside>

                  <div class="design-molecule-stage">
                    <section>
                      <h3>Actions</h3>
                      <div class="design-button-row">
                        <.ds_button variant="primary">
                          <.icon name="hero-check" class="size-4" /> Publish
                        </.ds_button>
                        <.ds_button>
                          <.icon name="hero-arrow-path" class="size-4" /> Refresh
                        </.ds_button>
                        <.ds_button variant="ghost">
                          <.icon name="hero-x-mark" class="size-4" /> Dismiss
                        </.ds_button>
                        <.ds_button variant="danger">
                          <.icon name="hero-trash" class="size-4" /> Remove
                        </.ds_button>
                      </div>
                    </section>

                    <section>
                      <h3>Selection And Status</h3>
                      <div class="design-button-row">
                        <.ds_chip label="v1" active />
                        <.ds_chip label="v2" />
                        <.ds_chip label="v3" />
                      </div>
                      <div class="design-status-row">
                        <span><.ds_status_mark status="added" /> Added</span>
                        <span><.ds_status_mark status="modified" /> Modified</span>
                        <span><.ds_status_mark status="deleted" /> Deleted</span>
                        <span><.ds_status_mark status="renamed" /> Renamed</span>
                      </div>
                    </section>

                    <section>
                      <h3>Native Navigation</h3>
                      <div class="design-nav-stack">
                        <.ds_nav_item navigate="/design" active>
                          <.icon name="hero-squares-2x2" class="size-4" /> Design system
                        </.ds_nav_item>
                        <.ds_nav_item navigate={~p"/r/uzRiKvyr"}>
                          <.icon name="hero-code-bracket-square" class="size-4" /> Review surface
                        </.ds_nav_item>
                      </div>
                    </section>
                  </div>
                </div>
              </div>
            </.ds_section>

            <.ds_section
              id="compounds"
              eyebrow="Compounds"
              title="Compounds create reusable review surfaces."
              description="A compound owns a small slice of workflow: a header, a file row, a section frame, or an empty state."
            >
              <div class="design-section-body">
                <div class="design-compound-grid">
                  <.ds_card>
                    <h3>Inventory</h3>
                    <div class="design-spec-list">
                      <div :for={compound <- @compounds}>
                        <strong>{compound.name}</strong>
                        <span>{compound.role}</span>
                      </div>
                    </div>
                  </.ds_card>

                  <.ds_card class="design-compound-preview">
                    <header class="design-review-header">
                      <div class="min-w-0">
                        <h3>Changed files</h3>
                        <p>4 files changed · 271 additions · 71 deletions</p>
                      </div>
                      <.ds_button variant="primary">Publish Review</.ds_button>
                    </header>
                    <div class="design-file-preview">
                      <.ds_file_link
                        :for={{file, index} <- Enum.with_index(@files)}
                        file={file}
                        current={index == 0}
                      />
                    </div>
                  </.ds_card>

                  <.ds_card class="design-compound-preview">
                    <div class="design-state-focus is-compact">
                      <.ds_empty_state
                        icon="hero-document-magnifying-glass"
                        title="No files in this patchset"
                        body="Keep the working surface visible, but let the empty message own the center."
                      >
                        <:actions>
                          <.ds_button>Refresh</.ds_button>
                        </:actions>
                      </.ds_empty_state>
                    </div>
                  </.ds_card>
                </div>
              </div>
            </.ds_section>

            <.ds_section
              id="organisms"
              eyebrow="Organisms"
              title="Full views are assembled from shared pieces."
              description="Organisms prove the system works under real density: topbar, navigation, file list, diff surface, and focused states."
            >
              <div class="design-section-body design-section-body-wide">
                <div class="design-organism-summary">
                  <div :for={organism <- @organisms}>
                    <strong>{organism.name}</strong>
                    <span>{organism.role}</span>
                  </div>
                </div>

                <article class="design-review-shell">
                  <header class="design-review-header">
                    <div class="min-w-0">
                      <h3 translate="no">Ship syntax highlighting and cleaned review navigation</h3>
                      <p>4 files changed · 271 additions · 71 deletions</p>
                    </div>
                    <div class="design-review-actions" aria-label="Review actions">
                      <.ds_chip label="v1" active />
                      <.ds_chip label="v2" />
                      <.ds_button variant="primary">Publish Review</.ds_button>
                    </div>
                  </header>

                  <.ds_split_view class="is-review">
                    <:sidebar>
                      <.ds_file_link
                        :for={{file, index} <- Enum.with_index(@files)}
                        file={file}
                        current={index == 0}
                      />
                    </:sidebar>
                    <:main>
                      <div id="design-diff" class="design-diff-preview" translate="no">
                        <div
                          :for={row <- @diff_rows}
                          class={[
                            "design-diff-line",
                            row.kind == :hunk && "is-hunk",
                            row.kind == :add && "is-add",
                            row.kind == :delete && "is-delete"
                          ]}
                        >
                          <span>{row.old}</span>
                          <span>{row.new}</span>
                          <code>{row.code}</code>
                        </div>
                      </div>
                    </:main>
                  </.ds_split_view>
                </article>
              </div>
            </.ds_section>
          </div>
        </.ds_shell>
      </main>
    </Layouts.app>
    """
  end

  defp taxonomy_levels do
    [
      %{index: "01", name: "Atoms", body: "Colors, typography, spacing, radius, icon rules."},
      %{index: "02", name: "Molecules", body: "Buttons, chips, nav items, status marks."},
      %{index: "03", name: "Compounds", body: "Headers, file rows, empty states, framed panels."},
      %{index: "04", name: "Organisms", body: "Complete review and settings surfaces."}
    ]
  end
end
