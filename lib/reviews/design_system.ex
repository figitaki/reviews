defmodule Reviews.DesignSystem do
  @moduledoc """
  Design-system reference data for the development playground.

  This keeps the `/design` LiveView focused on composition while the product
  language itself can evolve as named tokens, component examples, and patterns.
  """

  @colors [
    %{name: "Canvas", token: "--review-bg", value: "#000000", role: "App background"},
    %{name: "Panel", token: "--review-panel", value: "#050505", role: "Base surfaces"},
    %{name: "Raised", token: "--review-panel-raised", value: "#0b0b0c", role: "Menus and modals"},
    %{name: "Line", token: "--review-line", value: "#242426", role: "Subtle borders"},
    %{name: "Text", token: "--review-text", value: "#f5f5f5", role: "Primary copy"},
    %{name: "Muted", token: "--review-muted", value: "#a3a3a3", role: "Secondary copy"},
    %{name: "Add", token: "--review-add", value: "#25d0a0", role: "Inserted code"},
    %{name: "Delete", token: "--review-del", value: "#ff5f76", role: "Removed code"}
  ]

  @type_scale [
    %{name: "Display", sample: "Review diffs faster.", size: "72/0.9", role: "Page headers"},
    %{name: "Title", sample: "Changed files", size: "18/1.3", role: "Section and panel titles"},
    %{
      name: "Body",
      sample: "Chrome supports scanning and commenting.",
      size: "14/1.55",
      role: "Explanatory copy"
    },
    %{
      name: "Code",
      sample: "assets/js/hooks/diff_renderer.js",
      size: "12/1.58",
      role: "Paths and diffs"
    }
  ]

  @spacing [
    %{name: "Inline gap", value: "6px", role: "Icon/text pairs"},
    %{name: "Control radius", value: "6px", role: "Buttons, chips, inputs"},
    %{name: "Panel radius", value: "8px", role: "Cards, menus, modals"},
    %{name: "Section gutter", value: "24px", role: "Mobile-safe page inset"},
    %{name: "Review gap", value: "20px", role: "Sidebar/content split"}
  ]

  @icons [
    %{name: "hero-list-bullet", icon: "hero-list-bullet", role: "File and item lists"},
    %{name: "hero-view-columns", icon: "hero-view-columns", role: "Split page layouts"},
    %{name: "hero-squares-2x2", icon: "hero-squares-2x2", role: "System overview"},
    %{name: "hero-minus", icon: "hero-minus", role: "Section separation"},
    %{
      name: "hero-bars-3-bottom-left",
      icon: "hero-bars-3-bottom-left",
      role: "Text alignment cues"
    }
  ]

  @molecules [
    %{name: "Button", role: "In-place command", example: :buttons},
    %{name: "Patchset chip", role: "Small selected state", example: :chips},
    %{name: "Status mark", role: "File change shorthand", example: :status},
    %{name: "Nav item", role: "Phoenix route movement", example: :nav}
  ]

  @compounds [
    %{name: "Topbar", role: "Brand, navigation, global actions"},
    %{name: "Section header", role: "Eyebrow, title, short description"},
    %{name: "File row", role: "Status, path, additions, deletions"},
    %{name: "Empty state", role: "Focused no-data state with one action"}
  ]

  @organisms [
    %{name: "Focused page", role: "Single-column setup or settings workflow"},
    %{name: "Split review", role: "Sticky navigation rail with working canvas"},
    %{name: "Review detail", role: "Header, patchsets, file rail, diff surface"}
  ]

  @files [
    %{path: "assets/js/hooks/diff_renderer.js", status: "modified", additions: 48, deletions: 9},
    %{path: "assets/css/app.css", status: "modified", additions: 132, deletions: 18},
    %{
      path: "lib/reviews_web/live/review_live.ex",
      status: "modified",
      additions: 77,
      deletions: 44
    },
    %{path: "lib/reviews_web/live/design_live.ex", status: "added", additions: 214, deletions: 0}
  ]

  @diff_rows [
    %{old: 42, new: 42, kind: :hunk, code: "@@ render tokenized rows @@"},
    %{old: nil, new: 43, kind: :add, code: ~s(+ import { codeToTokens } from "shiki")},
    %{old: 43, new: 44, kind: :context, code: ~s(  const theme = "github-dark-default")},
    %{old: 44, new: nil, kind: :delete, code: "- render plain code text"}
  ]

  @states [
    %{icon: "hero-document-magnifying-glass", title: "Empty", body: "No files in this patchset."},
    %{icon: "hero-wifi", title: "Offline", body: "Keep drafts local until LiveView reconnects."},
    %{
      icon: "hero-lock-closed",
      title: "Read only",
      body: "Anonymous users can inspect, but not comment."
    }
  ]

  def colors, do: @colors
  def type_scale, do: @type_scale
  def spacing, do: @spacing
  def icons, do: @icons
  def molecules, do: @molecules
  def compounds, do: @compounds
  def organisms, do: @organisms
  def sample_files, do: @files
  def sample_diff_rows, do: @diff_rows
  def states, do: @states
end
