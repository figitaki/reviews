defmodule ReviewsWeb.ColocatedCSS do
  @moduledoc """
  Extracts `<style :type={ReviewsWeb.ColocatedCSS}>` blocks from HEEx templates
  at compile time into `phoenix-colocated/reviews/colocated.css`, which
  `assets/css/app.css` imports.

  CSS is emitted globally, unscoped. The app already namespaces classes by hand
  (`.l-*`, `.review-*`, `.ds-*`), so scoping would add noise without solving a
  real collision.
  """
  use Phoenix.LiveView.ColocatedCSS

  @impl true
  def transform("style", _attrs, css, _meta) do
    {:ok, css, []}
  end
end
