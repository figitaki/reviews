defmodule ReviewsWeb.LegalController do
  @moduledoc """
  The Privacy Policy (`/privacy`) and the Terms of Service (`/terms`).
  Both are drafts for the maintainer's review; see `ReviewsWeb.LegalHTML`.
  """
  use ReviewsWeb, :controller

  def privacy(conn, _params) do
    render(conn, :privacy, page_title: "Privacy Policy · Reviews")
  end

  def terms(conn, _params) do
    render(conn, :terms, page_title: "Terms of Service · Reviews")
  end
end
