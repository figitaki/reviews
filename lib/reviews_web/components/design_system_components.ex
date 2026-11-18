defmodule ReviewsWeb.DesignSystemComponents do
  @moduledoc """
  Product design primitives shared by the review and settings screens.
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
          <span class="design-brand-label">{@brand}</span>
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

  attr :id, :string, default: nil
  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :any, default: nil
  slot :inner_block
  slot :actions

  def ds_section(assigns) do
    ~H"""
    <section id={@id} class={["ds-section", @class]} aria-labelledby={@id && "#{@id}-title"}>
      <div class="ds-section-heading">
        <p :if={@eyebrow} class="ds-section-eyebrow">{@eyebrow}</p>
        <div>
          <h2 id={@id && "#{@id}-title"}>{@title}</h2>
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

  @variant_classes %{"primary" => "is-primary", "ghost" => "is-ghost", "danger" => "is-danger"}
  @size_classes %{"sm" => "is-sm", "lg" => "is-lg"}

  @doc """
  The one button. Pass `navigate`, `patch` or `href` to render it as a link
  that looks the same; otherwise it is a `<button type="button">`.

  `variant`: `primary` for the one main action in a view, `secondary` for
  the rest, `ghost` for low-emphasis actions inside panels, `danger` for
  destructive ones.

  `size`: `sm` (28px) in dense rows, `md` (32px, compact) in toolbars and
  panels, `lg` (40px, regular) in forms and page calls to action, the same
  height as a field. On touch screens every size keeps a 44px tap target.

  Hover and press change the surface only. Keyboard focus shows a ring in
  `--ds-focus`. `disabled` dims to 38% and stops clicks.
  """
  attr :variant, :string, default: "secondary", values: ~w(primary secondary ghost danger)
  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(type disabled form name value href navigate patch replace method download)

  slot :inner_block, required: true

  def ds_button(assigns) do
    assigns =
      assign(assigns,
        link?: Enum.any?([:href, :navigate, :patch], &Map.has_key?(assigns.rest, &1)),
        classes: [
          "ds-button",
          @variant_classes[assigns.variant],
          @size_classes[assigns.size],
          assigns.class
        ]
      )

    ~H"""
    <.link :if={@link?} class={@classes} {@rest}>{render_slot(@inner_block)}</.link>
    <button :if={!@link?} type={@rest[:type] || "button"} class={@classes} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  A pill-shaped filter or toggle link. `selected` fills it and sets
  `aria-current`. Pass `patch`, `navigate` or `href` as for `<.link>`.
  On touch screens the hit area grows to 44px without the pill growing.
  """
  attr :selected, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(patch navigate href replace)
  slot :inner_block, required: true

  def ds_chip(assigns) do
    ~H"""
    <.link
      class={["ds-chip", @selected && "is-selected", @class]}
      aria-current={@selected && "true"}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :body, :string, required: true
  slot :actions

  def ds_empty_state(assigns) do
    ~H"""
    <div class="ds-empty-state">
      <.icon name={@icon} class="ds-empty-icon size-5" />
      <h3>{@title}</h3>
      <p>{@body}</p>
      <div :if={@actions != []} class="ds-empty-actions">{render_slot(@actions)}</div>
    </div>
    """
  end
end
