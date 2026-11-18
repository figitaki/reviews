defmodule ReviewsWeb.ReviewDeletedError do
  @moduledoc """
  Raised when a page asks for a review its owner deleted. The endpoint turns
  it into a `410` response rendered by `ReviewsWeb.ErrorHTML`, which shows
  "This review was deleted" instead of a generic error.
  """
  defexception [:slug, plug_status: 410]

  @impl true
  def message(%{slug: slug}), do: "review #{slug} was deleted"
end
