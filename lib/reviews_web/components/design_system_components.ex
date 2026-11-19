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

  `icon` puts a Heroicon (`"hero-plus"`) before the label, and the `leading`
  slot any other mark, such as the GitHub mark. The `trailing` slot puts an
  icon after the label, such as the chevron on "Older". Put icons in these,
  not in the label, so they keep the button's gap and centring. Give controls an icon when it
  makes the action quicker to find: add, sign in, copy, page through, allow
  or deny. Leave it off where the label already says it.

  The label is wrapped in `.ds-label`, which centres its capitals in the
  button instead of the font's full ascent and descent.
  """
  attr :variant, :string, default: "secondary", values: ~w(primary secondary ghost danger)
  attr :size, :string, default: "md", values: ~w(sm md lg)
  attr :icon, :string, default: nil, doc: ~s(a Heroicon name such as "hero-plus")
  attr :class, :any, default: nil

  attr :rest, :global,
    include: ~w(type disabled form name value href navigate patch replace method download)

  slot :leading
  slot :trailing
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
    <.link :if={@link?} class={@classes} {@rest}>
      <.icon :if={@icon} name={@icon} class="ds-button-icon" />{render_slot(@leading)}<span class="ds-label">{render_slot(
        @inner_block
      )}</span>{render_slot(
        @trailing
      )}
    </.link>
    <button :if={!@link?} type={@rest[:type] || "button"} class={@classes} {@rest}>
      <.icon :if={@icon} name={@icon} class="ds-button-icon" />{render_slot(@leading)}<span class="ds-label">{render_slot(
        @inner_block
      )}</span>{render_slot(
        @trailing
      )}
    </button>
    """
  end

  @doc """
  The GitHub mark (the Invertocat), from Primer Octicons' `mark-github`.

  GitHub's logo guidelines allow it only in black, white or grey, unchanged
  and with enough contrast, so it takes `currentColor`: put it in text that
  is already black or white. It is decorative; the label next to it says
  "GitHub".
  """
  attr :class, :any, default: "size-4"

  def github_mark(assigns) do
    ~H"""
    <svg class={["ds-github-mark", @class]} viewBox="0 0 16 16" aria-hidden="true" focusable="false">
      <path
        fill="currentColor"
        d="M6.766 11.328c-2.063-.25-3.516-1.734-3.516-3.656 0-.781.281-1.625.75-2.188-.203-.515-.172-1.609.063-2.062.625-.078 1.468.25 1.968.703.594-.187 1.219-.281 1.985-.281.765 0 1.39.094 1.953.265.484-.437 1.344-.765 1.969-.687.218.422.25 1.515.046 2.047.5.593.766 1.39.766 2.203 0 1.922-1.453 3.375-3.547 3.64.531.344.89 1.094.89 1.954v1.625c0 .468.391.734.86.547C13.781 14.359 16 11.53 16 8.03 16 3.61 12.406 0 7.984 0 3.563 0 0 3.61 0 8.031a7.88 7.88 0 0 0 5.172 7.422c.422.156.828-.125.828-.547v-1.25c-.219.094-.5.156-.75.156-1.031 0-1.64-.562-2.078-1.609-.172-.422-.36-.672-.719-.719-.187-.015-.25-.093-.25-.187 0-.188.313-.328.625-.328.453 0 .844.281 1.25.86.313.452.64.655 1.031.655s.641-.14 1-.5c.266-.265.47-.5.657-.656"
      />
    </svg>
    """
  end

  @doc """
  The one GitHub sign-in control: a `<.ds_button>` with the GitHub mark.
  Pass `href` (usually `/auth/github?return_to=…`), or `type="submit"` inside
  a form. The label defaults to "Sign in with GitHub".
  """
  attr :variant, :string, default: "primary"
  attr :size, :string, default: "md"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(href type)
  slot :inner_block

  def ds_github_button(assigns) do
    ~H"""
    <.ds_button variant={@variant} size={@size} class={@class} {@rest}>
      <:leading><.github_mark class="ds-button-icon" /></:leading>
      <%= if @inner_block != [] do %>
        {render_slot(@inner_block)}
      <% else %>
        Sign in with GitHub
      <% end %>
    </.ds_button>
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

  @doc """
  An identity's square avatar: its image (a person's GitHub avatar, an agent's
  provider logo) or, without one, the first letter of its name. Decorative;
  put the name in text next to it.
  """
  attr :identity, :map, required: true
  attr :class, :any, default: nil

  def ds_avatar_mark(assigns) do
    ~H"""
    <span class={["ds-avatar-mark", @class]} aria-hidden="true">
      <img :if={@identity.avatar_url} src={@identity.avatar_url} alt="" loading="lazy" />
      <span :if={!@identity.avatar_url}>{avatar_initial(@identity.display_name)}</span>
    </span>
    """
  end

  defp avatar_initial(name) do
    case name |> to_string() |> String.trim() |> String.first() do
      nil -> "?"
      initial -> String.upcase(initial)
    end
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
