defmodule ReviewsWeb.SettingsLive do
  @moduledoc """
  Account settings: appearance, actor identities, and API tokens.
  """
  use ReviewsWeb, :live_view

  alias Reviews.Accounts

  @impl true
  def mount(_params, session, socket) do
    user = session["current_user_id"] && safe_load_user(session["current_user_id"])

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:new_token, nil)
      |> assign(:new_token_identity, nil)
      |> assign(:agent_form, to_form(%{}, as: :identity))
      |> assign(:token_form, to_form(%{}, as: :token))
      |> assign_account_data()

    {:ok, socket}
  end

  @impl true
  def handle_event("create_agent_identity", %{"identity" => params}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, "Sign in to manage identities.")}

      user ->
        case Accounts.create_agent_identity(user, params) do
          {:ok, _identity} ->
            {:noreply,
             socket
             |> assign(:agent_form, to_form(%{}, as: :identity))
             |> assign_account_data()
             |> put_flash(:info, "Agent identity created.")}

          {:error, changeset} ->
            {:noreply, assign(socket, :agent_form, to_form(changeset, as: :identity))}
        end
    end
  end

  @impl true
  def handle_event("mint_token", %{"token" => params}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, "Sign in to manage API tokens.")}

      user ->
        case Accounts.mint_token(user, params) do
          {:ok, token, raw} ->
            identity = token.identity || Accounts.get_identity!(token.identity_id)

            {:noreply,
             socket
             |> assign(:new_token, raw)
             |> assign(:new_token_identity, identity)
             |> assign(:token_form, to_form(%{}, as: :token))
             |> assign_account_data()
             |> put_flash(:info, "Token generated. Copy it now; it will not be shown again.")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :token_form, to_form(changeset, as: :token))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not generate token.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} chrome={false}>
      <main id="settings-page" class="l-page design-page">
        <Layouts.landing_topbar current_user={@current_user} />

        <div class="design-main is-settings">
          <.ds_page_header
            eyebrow="Settings"
            title="Account settings"
            description="Manage your review identity, agent identities, and CLI credentials."
            class="is-compact"
          >
            <:actions>
              <.link :if={!@current_user} href={~p"/auth/github"} class="ds-button is-primary">
                Sign in with GitHub
              </.link>
            </:actions>
          </.ds_page_header>

          <%= if @current_user do %>
            <div class="ds-settings-layout">
              <.ds_section
                id="appearance"
                eyebrow="Appearance"
                title="Theme"
                description="Choose how Reviews renders in this browser."
              >
                <div class="design-section-body">
                  <.ds_card class="ds-settings-card">
                    <div class="ds-settings-row">
                      <div>
                        <h3 id="appearance-theme-title">Theme</h3>
                        <p>Stored in this browser.</p>
                      </div>
                      <div class="ds-settings-row-control">
                        <Layouts.theme_toggle />
                      </div>
                    </div>
                  </.ds_card>
                </div>
              </.ds_section>

              <.ds_section
                id="identities"
                eyebrow="Identities"
                title="Review actors"
                description="Create distinct human and agent actors so comments, pushes, and decisions show the right source."
              >
                <div class="design-section-body">
                  <.ds_card class="ds-settings-card">
                    <div class="ds-identity-list">
                      <.identity_row
                        :if={@human_identity}
                        identity={@human_identity}
                        token_stats={Map.get(@identity_token_stats, @human_identity.id, %{count: 0})}
                        id="identity-human"
                      />

                      <.identity_row
                        :for={identity <- @agent_identities}
                        identity={identity}
                        token_stats={Map.get(@identity_token_stats, identity.id, %{count: 0})}
                        id={"identity-agent-#{identity.id}"}
                      />
                    </div>

                    <div :if={@agent_identities == []} class="ds-settings-empty-inline">
                      <.icon name="hero-cpu-chip" class="size-4" />
                      <span>No agent identities yet.</span>
                    </div>

                    <form
                      id="new-agent-identity-form"
                      phx-submit="create_agent_identity"
                      class="ds-settings-form"
                    >
                      <.input
                        field={@agent_form[:display_name]}
                        id="agent-display-name"
                        type="text"
                        label="Agent Name"
                        placeholder="Claude"
                        autocomplete="off"
                        class="ds-input"
                      />
                      <.input
                        field={@agent_form[:handle]}
                        id="agent-handle"
                        type="text"
                        label="Handle"
                        placeholder="claude"
                        autocomplete="off"
                        class="ds-input"
                      />
                      <.input
                        field={@agent_form[:provider]}
                        id="agent-provider"
                        type="text"
                        label="Provider"
                        placeholder="Claude, Codex, custom"
                        autocomplete="off"
                        class="ds-input"
                      />
                      <.ds_button type="submit" variant="primary" class="ds-settings-form-submit">
                        <.icon name="hero-plus" class="size-4" /> New agent identity
                      </.ds_button>
                    </form>
                  </.ds_card>
                </div>
              </.ds_section>

              <.ds_section
                id="access-tokens"
                eyebrow="Credentials"
                title="Access tokens"
                description="Mint one token per machine, CI job, or agent runtime."
              >
                <div class="design-section-body">
                  <.ds_card class="ds-settings-card">
                    <form id="mint-token-form" phx-submit="mint_token" class="ds-settings-form">
                      <.input
                        field={@token_form[:identity_id]}
                        id="token-identity-id"
                        type="select"
                        label="Acting Identity"
                        options={identity_options(@identities)}
                        class="ds-input"
                      />
                      <.input
                        field={@token_form[:name]}
                        id="token-name"
                        type="text"
                        label="Token Name"
                        placeholder="laptop"
                        autocomplete="off"
                        class="ds-input"
                      />
                      <.ds_button type="submit" variant="primary" class="ds-settings-form-submit">
                        <.icon name="hero-key" class="size-4" /> Generate token
                      </.ds_button>
                    </form>

                    <div
                      :if={@new_token}
                      id="new-token-banner"
                      class="ds-token-callout"
                      aria-live="polite"
                      translate="no"
                    >
                      <div>
                        <strong>New token</strong>
                        <span :if={@new_token_identity}>
                          for {identity_label(@new_token_identity)}
                        </span>
                        <em>Shown once</em>
                      </div>
                      <code>{@new_token}</code>
                    </div>

                    <.ds_empty_state
                      :if={@tokens == []}
                      icon="hero-key"
                      title="No API tokens yet"
                      body="Generate a token before using reviews push from the CLI."
                    />

                    <div :if={@tokens != []} id="tokens-list" class="ds-token-list">
                      <section
                        :for={{identity, tokens} <- tokens_by_identity(@identities, @tokens)}
                        id={"tokens-for-identity-#{identity.id}"}
                        class="ds-token-group"
                        aria-labelledby={"tokens-for-identity-#{identity.id}-title"}
                      >
                        <h3 id={"tokens-for-identity-#{identity.id}-title"}>
                          {identity_label(identity)}
                        </h3>
                        <ul>
                          <li :for={token <- tokens} id={"token-#{token.id}"} class="ds-token-row">
                            <span class="ds-token-row-name" translate="no">
                              {token.name || "(unnamed)"}
                            </span>
                            <span>{identity_label(identity)}</span>
                            <span>Created {format_date(token.inserted_at)}</span>
                            <span>{last_used_label(token.last_used_at)}</span>
                            <span class="ds-badge">Active</span>
                          </li>
                        </ul>
                      </section>
                    </div>
                  </.ds_card>
                </div>
              </.ds_section>
            </div>
          <% else %>
            <div class="design-state-focus">
              <.ds_empty_state
                icon="hero-key"
                title="Sign in to manage account settings"
                body="Settings are tied to your GitHub account so identities and credentials can be managed safely."
              >
                <:actions>
                  <.link href={~p"/auth/github"} class="ds-button is-primary">
                    Sign in with GitHub
                  </.link>
                </:actions>
              </.ds_empty_state>
            </div>
          <% end %>
        </div>
      </main>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :identity, :map, required: true
  attr :token_stats, :map, required: true

  defp identity_row(assigns) do
    ~H"""
    <article id={@id} class="ds-identity-row">
      <div class="ds-avatar-mark" aria-hidden="true">
        <img
          :if={@identity.avatar_url}
          src={@identity.avatar_url}
          alt=""
          width="36"
          height="36"
          loading="lazy"
        />
        <span :if={!@identity.avatar_url}>{identity_initial(@identity)}</span>
      </div>
      <div class="ds-identity-main">
        <h3>{@identity.display_name}</h3>
        <p translate="no">@{@identity.handle}</p>
      </div>
      <div class="ds-identity-meta">
        <span class="ds-badge">{String.capitalize(@identity.kind)}</span>
        <span :if={@identity.provider}>{@identity.provider}</span>
        <span>{@token_stats.count} {plural(@token_stats.count, "token")}</span>
        <span>{last_used_label(Map.get(@token_stats, :last_used_at))}</span>
      </div>
    </article>
    """
  end

  defp assign_account_data(%{assigns: %{current_user: nil}} = socket) do
    socket
    |> assign(:identities, [])
    |> assign(:human_identity, nil)
    |> assign(:agent_identities, [])
    |> assign(:identity_token_stats, %{})
    |> assign(:tokens, [])
  end

  defp assign_account_data(%{assigns: %{current_user: user}} = socket) do
    {:ok, human_identity} = Accounts.ensure_human_identity(user)
    identities = Accounts.list_identities_for(user)

    socket
    |> assign(:identities, identities)
    |> assign(:human_identity, human_identity)
    |> assign(:agent_identities, Enum.filter(identities, &(&1.kind == "agent")))
    |> assign(:identity_token_stats, Accounts.identity_token_counts(user))
    |> assign(:tokens, Accounts.list_tokens_for(user))
  end

  defp identity_options(identities) do
    Enum.map(identities, &{identity_label(&1), &1.id})
  end

  defp tokens_by_identity(identities, tokens) do
    tokens_by_identity_id = Enum.group_by(tokens, & &1.identity_id)

    identities
    |> Enum.map(fn identity -> {identity, Map.get(tokens_by_identity_id, identity.id, [])} end)
    |> Enum.filter(fn {_identity, tokens} -> tokens != [] end)
  end

  defp identity_label(identity), do: "#{identity.display_name} (@#{identity.handle})"

  defp identity_initial(identity) do
    identity.display_name
    |> to_string()
    |> String.trim()
    |> String.first()
    |> case do
      nil -> "?"
      initial -> String.upcase(initial)
    end
  end

  defp format_date(nil), do: "unknown"
  defp format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  defp format_date(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp last_used_label(nil), do: "Never used"
  defp last_used_label(dt), do: "Last used #{format_date(dt)}"

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"

  defp safe_load_user(id) do
    try do
      Accounts.get_user!(id)
    rescue
      Ecto.NoResultsError -> nil
    end
  end
end
