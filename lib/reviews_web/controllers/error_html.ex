defmodule ReviewsWeb.ErrorHTML do
  @moduledoc """
  This module is invoked by your endpoint in case of errors on HTML requests.

  See config/config.exs. The 404 page uses the root layout and the shared
  topbar; other statuses render their plain status text.
  """
  use ReviewsWeb, :html

  def render("404.html", assigns) do
    conn = assigns[:conn]

    assigns =
      assigns
      |> Map.put(:review?, match?(%ReviewsWeb.ReviewLive.NotFoundError{}, assigns[:reason]))
      |> Map.put(:current_user, conn && conn.assigns[:current_user])
      |> Map.put(:return_to, (conn && conn.request_path) || ~p"/")

    ~H"""
    <Layouts.app flash={%{}}>
      <div id="not-found" class="l-page design-page">
        <Layouts.landing_topbar
          current_user={@current_user}
          return_to={@return_to}
          show_workflow_anchor={false}
        />

        <div class="design-main">
          <div class="design-state-focus is-compact">
            <.ds_empty_state
              icon="hero-magnifying-glass"
              title={if @review?, do: "Review not found", else: "Page not found"}
              body={
                if @review?,
                  do:
                    "This review doesn't exist, or the link is wrong. Check the link, or ask whoever shared it.",
                  else: "There is nothing at this address. Check the link and try again."
              }
            >
              <:actions>
                <.link id="not-found-home" navigate={~p"/"} class="ds-button is-primary">
                  Go to the home page
                </.link>
              </:actions>
            </.ds_empty_state>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Other statuses render plain text based on the template name.
  # For example, "500.html" becomes "Internal Server Error".
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
