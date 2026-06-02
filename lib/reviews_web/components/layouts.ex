defmodule ReviewsWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ReviewsWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :chrome, :boolean,
    default: true,
    doc: "whether to render the default application chrome"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header :if={@chrome} class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" height="36" alt="" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <a href="https://phoenixframework.org/" class="btn btn-ghost">Website</a>
          </li>
          <li>
            <a href="https://github.com/phoenixframework/phoenix" class="btn btn-ghost">GitHub</a>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <li>
            <a href="https://hexdocs.pm/phoenix/overview.html" class="btn btn-primary">
              Get Started <span aria-hidden="true">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <div class={if(@chrome, do: "px-4 py-20 sm:px-6 lg:px-8", else: "p-0")}>
      <div class={if(@chrome, do: "mx-auto max-w-2xl space-y-4", else: "contents")}>
        {render_slot(@inner_block)}
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Shared landing-style topbar — used on `/` (HomeLive) and `/settings`
  (SettingsLive). Renders brand + a small nav + either a Sign-in CTA or a
  link to the current user's settings.

  Visual style: `.l-topbar` chrome from `landing.css` and `.r-*` components
  from `components.css`.
  """
  attr :current_user, :map,
    default: nil,
    doc: "the current user struct (or nil for signed-out visitors)"

  attr :show_workflow_anchor, :boolean,
    default: true,
    doc: "whether to include the in-page #chapter-push 'Workflow' anchor link"

  def landing_topbar(assigns) do
    ~H"""
    <header class="l-topbar">
      <div class="l-wrap l-topbar-inner">
        <.link navigate={~p"/"} class="r-brand" aria-label="Reviews home">
          <svg class="l-brand-mark-svg" viewBox="0 0 26 26" fill="none" aria-hidden="true">
            <rect
              x="0.75"
              y="0.75"
              width="24.5"
              height="24.5"
              rx="5.25"
              fill="currentColor"
              fill-opacity="0.04"
              stroke="currentColor"
              stroke-opacity="0.32"
              stroke-width="1"
            >
            </rect>
            <path
              d="M8.6 18.5V7.5h4.65c1.45 0 2.55 0.36 3.3 1.07 0.76 0.71 1.14 1.64 1.14 2.78 0 0.85-0.22 1.58-0.66 2.18-0.43 0.6-1.05 1.04-1.86 1.32L18.6 18.5h-2.45l-2.92-3.36h-2.18V18.5H8.6Zm2.45-5.35h2.07c0.73 0 1.3-0.17 1.7-0.5 0.4-0.34 0.6-0.81 0.6-1.42 0-0.6-0.2-1.07-0.6-1.4-0.4-0.34-0.97-0.5-1.7-0.5h-2.07v3.82Z"
              fill="currentColor"
            >
            </path>
          </svg>
          <span>Reviews</span>
        </.link>

        <nav class="l-nav" aria-label="Primary">
          <a :if={@show_workflow_anchor} class="r-nav-item" href="/#chapter-push">Workflow</a>
          <a class="r-nav-item" href="https://github.com/figitaki/reviews">
            GitHub <span aria-hidden="true">↗</span>
          </a>

          <%= if @current_user do %>
            <.link
              navigate={~p"/settings"}
              class="r-nav-item l-nav-user"
              aria-label={"Signed in as #{@current_user.username}"}
            >
              <img
                :if={@current_user.avatar_url}
                src={@current_user.avatar_url}
                alt=""
                class="l-nav-avatar"
                width="20"
                height="20"
              />
              <span>{@current_user.username}</span>
            </.link>
          <% else %>
            <.link href={~p"/auth/github"} class="r-button r-button-primary l-nav-signin">
              Sign in
            </.link>
          <% end %>
        </nav>
      </div>
    </header>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 translate-x-0 [[data-theme=light]_&]:translate-x-full [[data-theme=dark]_&]:translate-x-[200%] transition-transform motion-reduce:transition-none" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
