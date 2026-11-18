defmodule ReviewsWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs. Most errors still render the plain status text.
  `status_page/1` is the styled page for errors a visitor should understand:
  it renders a deleted review (`ReviewsWeb.ReviewDeletedError`, 410) now, and
  the "Better 404 page" issue (#180) can render its 404s with it too.
  """
  use ReviewsWeb, :html

  def render("410.html", %{reason: %ReviewsWeb.ReviewDeletedError{}} = assigns) do
    assigns =
      assigns
      |> Map.put(:page_title, "Review deleted")
      |> Map.put(:current_user, assigns[:current_user])

    page = ~H"""
    <.status_page
      id="review-deleted"
      title="This review was deleted"
      current_user={@current_user}
      return_to={@conn.request_path}
    >
      Its owner deleted it, with its revisions and comments. It can't be restored.
      If you expected to see it, ask whoever shared the link.
    </.status_page>
    """

    Layouts.root(Map.put(assigns, :inner_content, page))
  end

  # The default is to render a plain text page based on
  # the template name. For example, "404.html" becomes
  # "Not Found".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end

  @doc """
  A full error page in the app's style: the shared topbar, a title that says
  what happened, a short explanation, and a link home. Render it inside the
  root layout, since the endpoint renders errors without one.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :current_user, :any, default: nil
  attr :return_to, :string, default: "/"
  slot :inner_block, required: true

  def status_page(assigns) do
    ~H"""
    <div id={@id} class="l-page">
      <Layouts.landing_topbar
        current_user={@current_user}
        show_workflow_anchor={false}
        return_to={@return_to}
      />
      <section class="home-content l-status" aria-labelledby={"#{@id}-title"}>
        <h1 id={"#{@id}-title"}>{@title}</h1>
        <p class="l-status-message">{render_slot(@inner_block)}</p>
        <div class="home-actions">
          <.link id={"#{@id}-home"} navigate={~p"/"} class="r-button r-button-primary">
            Go to Reviews home
          </.link>
        </div>
      </section>
    </div>
    """
  end
end
