defmodule ReviewsWeb.SettingsLive do
  @moduledoc """
  Per-user settings page. v1 has one feature: mint an API token for the CLI.

  Tokens are opaque — we generate one, show it ONCE in the flash/banner, and
  only persist its SHA-256 hash. Subsequent visits show token *metadata* (name,
  last_used_at) but never the raw value.
  """
  use ReviewsWeb, :live_view

  alias Reviews.Accounts

  @impl true
  def mount(_params, session, socket) do
    user_id = session["current_user_id"]

    case user_id && safe_load_user(user_id) do
      nil ->
        {:ok,
         socket
         |> assign(:current_user, nil)
         |> assign(:tokens, [])
         |> assign(:new_token, nil)}

      user ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:tokens, Accounts.list_tokens_for(user))
         |> assign(:new_token, nil)}
    end
  end

  @impl true
  def handle_event("mint_token", %{"name" => name}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, "Sign in to manage API tokens.")}

      user ->
        case Accounts.mint_token(user, %{"name" => name}) do
          {:ok, _token, raw} ->
            {:noreply,
             socket
             |> assign(:new_token, raw)
             |> assign(:tokens, Accounts.list_tokens_for(user))
             |> put_flash(:info, "Token generated. Copy it now — it will not be shown again.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not generate token.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} chrome={false}>
      <main id="settings-page" class="design-page">
        <.ds_shell brand="Reviews" home={~p"/"}>
          <:nav>
            <.ds_nav_item navigate={~p"/"}>Home</.ds_nav_item>
            <.ds_nav_item navigate={~p"/r/uzRiKvyr"}>Review sample</.ds_nav_item>
            <.ds_nav_item navigate={~p"/settings"} active>Settings</.ds_nav_item>
          </:nav>
          <:actions>
            <Layouts.theme_toggle />
          </:actions>

          <div class="design-main">
            <.ds_page_header
              eyebrow="Settings"
              title="API tokens for the reviews CLI."
              description="Mint scoped credentials for local pushes. Generated tokens are shown once, then stored only as a hash."
            >
              <:actions>
                <.link :if={!@current_user} href={~p"/auth/github"} class="ds-button is-primary">
                  Sign in with GitHub
                </.link>
              </:actions>
            </.ds_page_header>

            <.ds_section
              id="api-tokens"
              eyebrow="Credentials"
              title="Token access"
              description="Name each token after the machine or automation that will use it."
            >
              <div class="design-section-body">
                <.ds_card class="min-h-0">
                  <%= if @current_user do %>
                    <form
                      id="mint-token-form"
                      phx-submit="mint_token"
                      class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end"
                    >
                      <.input
                        id="token-name"
                        name="name"
                        type="text"
                        value=""
                        label="Token Name"
                        placeholder="laptop"
                        autocomplete="off"
                        class="h-10 w-full rounded-md border border-[color:var(--ds-line-strong)] bg-[color:var(--ds-panel)] px-3 text-sm text-[color:var(--ds-text)] outline-none transition placeholder:text-[color:var(--ds-faint)] focus:border-[color:var(--ds-text)] focus:ring-2 focus:ring-[color:var(--ds-line)]"
                      />
                      <.ds_button type="submit" variant="primary" class="mb-2">
                        <.icon name="hero-key" class="size-4" /> Generate token
                      </.ds_button>
                    </form>

                    <div
                      :if={@new_token}
                      id="new-token-banner"
                      translate="no"
                      class="mt-4 rounded-md border border-[color:var(--ds-line)] bg-[color:var(--ds-panel-raised)] p-3 font-mono text-sm break-all text-[color:var(--ds-text)]"
                    >
                      {@new_token}
                    </div>

                    <div class="mt-6 border-t border-[color:var(--ds-line)] pt-3">
                      <.ds_empty_state
                        :if={@tokens == []}
                        icon="hero-key"
                        title="No API tokens yet"
                        body="Generate a token before using reviews push from the CLI."
                      />

                      <ul
                        :if={@tokens != []}
                        id="tokens-list"
                        class="divide-y divide-[color:var(--ds-line)]"
                      >
                        <li
                          :for={t <- @tokens}
                          id={"token-#{t.id}"}
                          class="flex flex-col gap-1 py-3 sm:flex-row sm:items-baseline sm:justify-between"
                        >
                          <span
                            translate="no"
                            class="min-w-0 font-medium text-[color:var(--ds-text)] break-words"
                          >
                            {t.name || "(unnamed)"}
                          </span>
                          <span class="text-xs text-[color:var(--ds-muted)]">
                            Created {Calendar.strftime(t.inserted_at, "%Y-%m-%d")}
                          </span>
                        </li>
                      </ul>
                    </div>
                  <% else %>
                    <div class="design-state-focus is-compact">
                      <.ds_empty_state
                        icon="hero-key"
                        title="Sign in to manage API tokens"
                        body="Tokens are tied to your account so generated credentials can be listed and revoked safely."
                      >
                        <:actions>
                          <.link href={~p"/auth/github"} class="ds-button is-primary">
                            Sign in with GitHub
                          </.link>
                        </:actions>
                      </.ds_empty_state>
                    </div>
                  <% end %>
                </.ds_card>
              </div>
            </.ds_section>
          </div>
        </.ds_shell>
      </main>
    </Layouts.app>
    """
  end

  defp safe_load_user(id) do
    try do
      Accounts.get_user!(id)
    rescue
      Ecto.NoResultsError -> nil
    end
  end
end
