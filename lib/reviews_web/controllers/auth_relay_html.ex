defmodule ReviewsWeb.AuthRelayHTML do
  @moduledoc false
  use ReviewsWeb, :html

  # The relay asks before it signs anyone in to a preview. Fly app names are
  # global, so a reviews-pr-<N> host can belong to someone else; without this
  # step, any page could send an already-authorized visitor through the relay
  # and learn who they are on GitHub.
  def confirm(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="auth-relay-confirm" class="l-page design-page">
        <div class="design-main is-settings">
          <.ds_page_header
            eyebrow="Preview sign-in"
            title={"Sign in to #{@host}"}
            description="GitHub confirms who you are, then you go back to this preview, signed in. Continue only if you started from this preview."
            class="is-compact"
          >
            <:actions>
              <.form for={%{}} action={~p"/auth/relay"} method="post">
                <input type="hidden" name="host" value={@host} />
                <input type="hidden" name="state" value={@state} />
                <.ds_github_button type="submit">Continue with GitHub</.ds_github_button>
              </.form>
            </:actions>
          </.ds_page_header>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
