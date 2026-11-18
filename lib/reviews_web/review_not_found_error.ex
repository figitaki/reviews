defmodule ReviewsWeb.ReviewNotFoundError do
  @moduledoc """
  Raised when a page asks for a review that never existed. The endpoint turns
  it into a `404` response rendered by `ReviewsWeb.ErrorHTML`, which shows
  "Review not found" instead of sending the visitor home.
  """
  defexception [:slug, plug_status: 404]

  @impl true
  def message(%{slug: slug}), do: "review #{slug} not found"
end
