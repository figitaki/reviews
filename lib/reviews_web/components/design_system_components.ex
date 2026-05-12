defmodule ReviewsWeb.DesignSystemComponents do
  @moduledoc """
  Product design primitives shared by the review UI and `/design` playground.
  """
  use Phoenix.Component

  import ReviewsWeb.CoreComponents, only: [icon: 1]

  attr :brand, :string, required: true
  attr :home, :string, required: true
  slot :nav
  slot :actions
  slot :inner_block, required: true

  def ds_shell(assigns) do
    ~H"""
    <div class="ds-shell">
      <header class="ds-shell-topbar">
        <.link navigate={@home} class="design-brand" aria-label={"#{@brand} home"}>
          <span class="design-brand-mark" aria-hidden="true">R</span>
          <span>{@brand}</span>
        </.link>

        <nav :if={@nav != []} class="ds-shell-nav" aria-label="Primary">
          {render_slot(@nav)}
        </nav>

        <div :if={@actions != []} class="ds-shell-actions">{render_slot(@actions)}</div>
      </header>

      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :any, default: nil
  slot :actions

  def ds_page_header(assigns) do
    ~H"""
    <header class={["ds-page-header", @class]}>
      <div>
        <p :if={@eyebrow} class="design-kicker">
          <span aria-hidden="true"></span>
          {@eyebrow}
        </p>
        <h1>{@title}</h1>
        <p :if={@description} class="design-hero-copy">{@description}</p>
      </div>
      <div :if={@actions != []} class="ds-page-header-actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  def ds_nav_item(assigns) do
    ~H"""
    <.link navigate={@navigate} class={["ds-nav-item", @active && "is-active"]}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :id, :string, default: nil
  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block
  slot :actions

  def ds_section(assigns) do
    ~H"""
    <section id={@id} class={["ds-section", @class]}>
      <div class="ds-section-heading">
        <p :if={@eyebrow} class="ds-section-eyebrow">{@eyebrow}</p>
        <div>
          <h2>{@title}</h2>
          <p :if={@description} class="ds-section-description">{@description}</p>
        </div>
        <div :if={@actions != []} class="ds-section-actions">{render_slot(@actions)}</div>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :class, :any, default: nil
  slot :inner_block, required: true

  def ds_card(assigns) do
    ~H"""
    <article class={["ds-card", @class]}>
      {render_slot(@inner_block)}
    </article>
    """
  end

  attr :class, :any, default: nil
  slot :sidebar, required: true
  slot :main, required: true

  def ds_split_view(assigns) do
    ~H"""
    <div class={["ds-split-view", @class]}>
      <aside class="ds-split-sidebar">{render_slot(@sidebar)}</aside>
      <section class="ds-split-main">{render_slot(@main)}</section>
    </div>
    """
  end

  attr :variant, :string, default: "secondary", values: ~w(primary secondary ghost danger)
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(type disabled aria-label phx-click phx-value-number)
  slot :inner_block, required: true

  def ds_button(assigns) do
    ~H"""
    <button
      type={@rest[:type] || "button"}
      class={[
        "ds-button",
        @variant == "primary" && "is-primary",
        @variant == "ghost" && "is-ghost",
        @variant == "danger" && "is-danger",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :label, :string, required: true
  attr :active, :boolean, default: false
  attr :rest, :global, include: ~w(type aria-pressed phx-click phx-value-number)

  def ds_chip(assigns) do
    ~H"""
    <button
      type={@rest[:type] || "button"}
      class={["ds-chip", @active && "is-active"]}
      aria-pressed={to_string(@active)}
      {@rest}
    >
      {@label}
    </button>
    """
  end

  attr :status, :string, required: true
  attr :class, :any, default: nil

  def ds_status_mark(assigns) do
    ~H"""
    <span class={[
      "rev-status-icon",
      @status == "added" && "is-added",
      @status == "modified" && "is-modified",
      @status == "deleted" && "is-deleted",
      @status == "renamed" && "is-renamed",
      @class
    ]}>
      {status_letter(@status)}
    </span>
    """
  end

  attr :file, :map, required: true
  attr :current, :boolean, default: false

  def ds_file_link(assigns) do
    ~H"""
    <a href="#design-diff" class={["ds-file-link", @current && "is-current"]}>
      <span class="flex items-center gap-2 min-w-0">
        <.ds_status_mark status={@file.status} />
        <span class="ds-code truncate" translate="no">{@file.path}</span>
      </span>
      <span class="rev-file-stats">
        <span class="rev-stat-add">+{@file.additions}</span>
        <span class="rev-stat-del">-{@file.deletions}</span>
      </span>
    </a>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :role, :string, required: true

  def ds_token(assigns) do
    ~H"""
    <div class="ds-token" style={"--token-color: #{@value}"}>
      <span aria-hidden="true"></span>
      <strong>{@label}</strong>
      <code>{@value}</code>
      <em>{@role}</em>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true

  def ds_state(assigns) do
    ~H"""
    <article class="ds-state">
      <.icon name={@icon} class="size-5" />
      <h3>{@title}</h3>
      <p>{@body}</p>
    </article>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true
  slot :actions

  def ds_empty_state(assigns) do
    ~H"""
    <div class="ds-empty-state">
      <.icon name={@icon} class="size-5" />
      <h3>{@title}</h3>
      <p>{@body}</p>
      <div :if={@actions != []} class="ds-empty-actions">{render_slot(@actions)}</div>
    </div>
    """
  end

  attr :name, :string, required: true

  def ds_catalog_icon(%{name: "hero-list-bullet"} = assigns) do
    ~H"""
    <.icon name="hero-list-bullet" class="size-4" />
    """
  end

  def ds_catalog_icon(%{name: "hero-view-columns"} = assigns) do
    ~H"""
    <.icon name="hero-view-columns" class="size-4" />
    """
  end

  def ds_catalog_icon(%{name: "hero-squares-2x2"} = assigns) do
    ~H"""
    <.icon name="hero-squares-2x2" class="size-4" />
    """
  end

  def ds_catalog_icon(%{name: "hero-minus"} = assigns) do
    ~H"""
    <.icon name="hero-minus" class="size-4" />
    """
  end

  def ds_catalog_icon(%{name: "hero-bars-3-bottom-left"} = assigns) do
    ~H"""
    <.icon name="hero-bars-3-bottom-left" class="size-4" />
    """
  end

  def ds_catalog_icon(assigns) do
    ~H"""
    <.icon name="hero-x-mark" class="size-4" />
    """
  end

  defp status_letter("added"), do: "A"
  defp status_letter("modified"), do: "M"
  defp status_letter("deleted"), do: "D"
  defp status_letter("renamed"), do: "R"
  defp status_letter(_), do: "?"
end
