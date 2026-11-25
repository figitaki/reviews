defmodule ReviewsWeb.StaleAssets do
  @moduledoc """
  Tells a tab that its CSS and JS are out of date (issue #268).

  A tab left open across a deploy reconnects to the new release and renders
  the new markup, but keeps the stylesheet and script it loaded before. The
  root layout marks those assets with `phx-track-static`, so on a connected
  mount `Phoenix.LiveView.static_changed?/1` reports the change. This hook
  then puts an `:assets_changed` flash, which `ReviewsWeb.Layouts.flash_group/1`
  shows with a link that reloads the page.

  It asks rather than reloads: an open comment composer holds its text only
  in the page. The toast reuses the existing flash markup, so it renders with
  the tab's old CSS too.
  """
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) and static_changed?(socket) do
      {:cont, put_flash(socket, :assets_changed, "A new version of Reviews is available.")}
    else
      {:cont, socket}
    end
  end
end
