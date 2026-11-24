defmodule ReviewsWeb.LegalController do
  @moduledoc """
  The Privacy Policy (`/privacy`) and the Terms of Service (`/terms`), as the
  deployment configures them (`Reviews.Legal`): the built-in template filled
  in from config, a redirect to the operator's own policy, or a 404 when the
  deployment has none.
  """
  use ReviewsWeb, :controller

  def privacy(conn, _params), do: show(conn, :privacy, "Privacy Policy")
  def terms(conn, _params), do: show(conn, :terms, "Terms of Service")

  defp show(conn, kind, title) do
    case Reviews.Legal.document(kind) do
      {:template, fields} ->
        render(conn, kind, page_title: "#{title} · Reviews", legal: fields)

      {:url, url} ->
        redirect(conn, external: url)

      nil ->
        raise Phoenix.Router.NoRouteError, conn: conn, router: ReviewsWeb.Router
    end
  end
end
