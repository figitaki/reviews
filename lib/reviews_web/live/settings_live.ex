defmodule ReviewsWeb.SettingsLive do
  @moduledoc """
  Account settings: appearance, actor identities, and API tokens.
  """
  use ReviewsWeb, :live_view

  alias Reviews.Accounts
  alias Reviews.Accounts.AgentProviders
  alias Reviews.OAuth

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
  def handle_event("change_agent_identity", %{"identity" => params}, socket) do
    {:noreply, assign(socket, :agent_form, to_form(params, as: :identity))}
  end

  def handle_event("create_agent_identity", %{"identity" => params}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, "Sign in to manage identities.")}

      user ->
        case Accounts.create_agent_identity(user, agent_identity_attrs(socket, params)) do
          {:ok, _identity} ->
            {:noreply,
             socket
             |> assign(:agent_form, to_form(%{}, as: :identity))
             |> assign_account_data()
             |> put_flash(:info, "Agent identity created.")}

          # Keep what was typed, including a custom provider, next to the errors.
          {:error, changeset} ->
            form = to_form(params, as: :identity, errors: changeset.errors, action: :insert)
            {:noreply, assign(socket, :agent_form, form)}
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
  def handle_event("revoke_token", %{"id" => id}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, "Sign in to manage API tokens.")}

      user ->
        case Accounts.revoke_token(user, id) do
          :ok ->
            {:noreply,
             socket
             |> assign(:new_token, nil)
             |> assign(:new_token_identity, nil)
             |> assign_account_data()
             |> put_flash(:info, "Token revoked. It can no longer access the API.")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Token not found.")}
        end
    end
  end

  @impl true
  def handle_event("revoke_agent_link", %{"id" => id}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, "Sign in to manage connected agents.")}

      user ->
        case OAuth.revoke_grant(user, id) do
          :ok ->
            {:noreply,
             socket
             |> assign_account_data()
             |> put_flash(:info, "Agent disconnected. Its tokens stopped working.")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Connected agent not found.")}
        end
    end
  end

  def handle_event("sign_out_cli", %{"id" => id}, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, "Sign in to manage CLI sign-ins.")}

      user ->
        case OAuth.revoke_grant(user, id) do
          :ok ->
            {:noreply,
             socket
             |> assign_account_data()
             |> put_flash(:info, "CLI signed out. Run reviews login there to sign in again.")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "CLI sign-in not found.")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="settings-page" class="l-page design-page">
        <Layouts.landing_topbar current_user={@current_user} return_to={~p"/settings"} />

        <div class="design-main is-settings">
          <.ds_page_header
            eyebrow="Settings"
            title="Account settings"
            description="Manage your review identity, agent identities, and CLI credentials."
            class="is-compact"
          >
            <:actions>
              <.ds_github_button
                :if={!@current_user}
                href={~p"/auth/github?return_to=/settings"}
              >
                Sign in with GitHub
              </.ds_github_button>
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
                        :key={identity.id}
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
                      phx-change="change_agent_identity"
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
                      />
                      <.input
                        field={@agent_form[:handle]}
                        id="agent-handle"
                        type="text"
                        label="Handle"
                        placeholder="claude"
                        autocomplete="off"
                      />
                      <.input
                        field={@agent_form[:provider]}
                        id="agent-provider"
                        type="select"
                        label="Provider"
                        prompt="None"
                        options={provider_options()}
                      />
                      <.input
                        :if={@agent_form[:provider].value == "custom"}
                        field={@agent_form[:custom_provider]}
                        id="agent-custom-provider"
                        type="text"
                        label="Custom Provider"
                        placeholder="My agent platform"
                        autocomplete="off"
                      />
                      <.ds_button
                        type="submit"
                        variant="primary"
                        size="lg"
                        class="ds-settings-form-submit"
                        icon="hero-plus"
                      >
                        New agent identity
                      </.ds_button>
                    </form>
                  </.ds_card>
                </div>
              </.ds_section>

              <.ds_section
                id="cli-sign-ins"
                eyebrow="Reviews CLI"
                title="CLI sign-ins"
                description="Each reviews login you approved, and the identity it acts as. Signing one out stops its tokens at once."
              >
                <div class="design-section-body">
                  <.ds_card class="ds-settings-card">
                    <.ds_empty_state
                      :if={@cli_sessions == []}
                      icon="hero-command-line"
                      title="No CLI sign-ins"
                      body="Run reviews login, then enter the code it shows at /device."
                    />
                    <ul :if={@cli_sessions != []} id="cli-sessions-list" class="ds-token-list">
                      <li
                        :for={session <- @cli_sessions}
                        :key={session.id}
                        id={"cli-session-#{session.id}"}
                        class="ds-token-row"
                      >
                        <span class="ds-token-row-name">Reviews CLI</span>
                        <span :if={session.identity}>
                          Acts as {identity_label(session.identity)}.
                        </span>
                        <span>
                          Signed in {format_date(session.inserted_at)}. {last_used_label(
                            session.last_used_at
                          )}.
                        </span>
                        <.ds_button
                          id={"sign-out-cli-#{session.id}"}
                          variant="danger"
                          icon="hero-arrow-right-start-on-rectangle"
                          phx-click="sign_out_cli"
                          phx-value-id={session.id}
                          data-confirm="Sign this CLI out? Its tokens stop working at once."
                          aria-label={"Sign out the CLI signed in #{format_date(session.inserted_at)}"}
                        >
                          Sign out
                        </.ds_button>
                      </li>
                    </ul>
                  </.ds_card>
                </div>
              </.ds_section>

              <.ds_section
                id="connected-agents"
                eyebrow="OAuth"
                title="Connected agents"
                description="Apps you allowed to act as one of your agent identities. Disconnecting stops their tokens at once; their earlier comments keep their attribution."
              >
                <div class="design-section-body">
                  <.ds_card class="ds-settings-card">
                    <.ds_empty_state
                      :if={@agent_links == []}
                      icon="hero-link"
                      title="No connected agents"
                      body="An app can ask to connect to one of your agent identities. You approve it on a Reviews page."
                    />
                    <ul :if={@agent_links != []} id="agent-links-list" class="ds-token-list">
                      <li
                        :for={link <- @agent_links}
                        :key={link.id}
                        id={"agent-link-#{link.id}"}
                        class="ds-token-row"
                      >
                        <span class="ds-token-row-name" translate="no">
                          {link_label(link)}
                        </span>
                        <span>
                          Acts as {identity_label(link.identity)}. Calls itself {link.client_name ||
                            "(no name)"} (not verified).
                        </span>
                        <span translate="no">{Enum.join(link.scopes, " ")}</span>
                        <span>
                          Approved {format_date(link.inserted_at)}. {last_used_label(
                            link.last_used_at
                          )}.
                        </span>
                        <span :if={link.revoked_at} class="ds-badge">
                          Disconnected {format_date(link.revoked_at)}
                        </span>
                        <.ds_button
                          :if={!link.revoked_at}
                          id={"revoke-agent-link-#{link.id}"}
                          variant="danger"
                          icon="hero-link-slash"
                          phx-click="revoke_agent_link"
                          phx-value-id={link.id}
                          data-confirm="Disconnect this agent? Its tokens stop working at once."
                          aria-label={"Disconnect #{link_label(link)}"}
                        >
                          Disconnect
                        </.ds_button>
                      </li>
                    </ul>
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
                      />
                      <.input
                        field={@token_form[:name]}
                        id="token-name"
                        type="text"
                        label="Token Name"
                        placeholder="laptop"
                        autocomplete="off"
                      />
                      <.ds_button
                        type="submit"
                        variant="primary"
                        size="lg"
                        class="ds-settings-form-submit"
                        icon="hero-key"
                      >
                        Generate token
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
                        :key={identity.id}
                        id={"tokens-for-identity-#{identity.id}"}
                        class="ds-token-group"
                        aria-labelledby={"tokens-for-identity-#{identity.id}-title"}
                      >
                        <h3 id={"tokens-for-identity-#{identity.id}-title"}>
                          {identity_label(identity)}
                        </h3>
                        <ul>
                          <li
                            :for={token <- tokens}
                            :key={token.id}
                            id={"token-#{token.id}"}
                            class="ds-token-row"
                          >
                            <span class="ds-token-row-name" translate="no">
                              {token.name || "(unnamed)"}
                            </span>
                            <span>{identity_label(identity)}</span>
                            <span>Created {format_date(token.inserted_at)}</span>
                            <span>{last_used_label(token.last_used_at)}</span>
                            <.ds_button
                              id={"revoke-token-#{token.id}"}
                              variant="danger"
                              icon="hero-no-symbol"
                              phx-click="revoke_token"
                              phx-value-id={token.id}
                              data-confirm="Revoke this token? Anything using it will lose API access."
                              aria-label={"Revoke token #{token.name || "(unnamed)"}"}
                            >
                              Revoke
                            </.ds_button>
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
                  <.ds_github_button href={~p"/auth/github?return_to=/settings"}>
                    Sign in with GitHub
                  </.ds_github_button>
                </:actions>
              </.ds_empty_state>
            </div>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :identity, :map, required: true
  attr :token_stats, :map, required: true

  defp identity_row(assigns) do
    ~H"""
    <article id={@id} class="ds-identity-row">
      <.ds_avatar_mark identity={@identity} />
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
    |> assign(:agent_links, [])
    |> assign(:cli_sessions, [])
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
    |> assign_grants(OAuth.list_grants_for(user))
  end

  # CLI sign-ins act as the person and get their own section; revoked ones
  # are gone for good, so only active ones show.
  defp assign_grants(socket, grants) do
    {cli, agents} = Enum.split_with(grants, &(&1.client_id == OAuth.CLI.client_id()))

    socket
    |> assign(:agent_links, agents)
    |> assign(:cli_sessions, Enum.filter(cli, &is_nil(&1.revoked_at)))
  end

  # A registered client has no domain; it goes by the name it gave.
  defp link_label(%{client_id: client_id} = grant) do
    case URI.parse(client_id) do
      %URI{scheme: "https", host: host} when is_binary(host) -> host
      _ -> "#{grant.client_name || "Unnamed app"} (registered app)"
    end
  end

  defp provider_options do
    Enum.map(AgentProviders.all(), &{&1.name, &1.name}) ++ [{"Custom", "custom"}]
  end

  # The provider is a listed one or the custom name typed. A listed provider
  # (also when typed as custom) gives the identity its logo as the avatar,
  # as an absolute URL because API and diff payloads require one.
  defp agent_identity_attrs(socket, params) do
    provider =
      if params["provider"] == "custom", do: params["custom_provider"], else: params["provider"]

    provider = if is_binary(provider) and String.trim(provider) != "", do: String.trim(provider)
    listed = AgentProviders.get(provider)

    %{
      "display_name" => params["display_name"],
      "handle" => params["handle"],
      "provider" => if(listed, do: listed.name, else: provider),
      "avatar_url" => listed && static_url(socket, listed.logo)
    }
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
