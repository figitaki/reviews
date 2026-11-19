defmodule ReviewsWeb.OAuthHTML do
  @moduledoc """
  Pages for the OAuth issuer: sign in, consent, and an invalid request.

  The consent page names the client by the domain that published its
  metadata document (its `client_id` host) and shows its `client_name` only
  as what it calls itself, so an unverified name is never shown as verified.
  A client the resource recognizes by its `client_id` (`known_client/1`),
  such as Claude or ChatGPT at `/mcp`, is shown with its name and logo.
  A client registered through dynamic client registration has no verified
  domain, so the page says so and leads with the host it sends you back to.

  The wording comes from the requested resource
  (`c:Reviews.OAuth.Resource.consent_text/1`).
  """
  use ReviewsWeb, :html

  def sign_in(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="poppy-sign-in" class="l-page design-page">
        <div class="design-main is-settings">
          <.ds_page_header
            eyebrow={eyebrow(@request)}
            title="Sign in to continue"
            description={sign_in_text(@request)}
            class="is-compact"
          >
            <:actions>
              <.ds_github_button
                id="poppy-sign-in-github"
                href={~p"/auth/github?#{[return_to: @return_to]}"}
              >
                Sign in with GitHub
              </.ds_github_button>
            </:actions>
          </.ds_page_header>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def consent(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="poppy-consent" class="l-page design-page">
        <div class="design-main is-settings">
          <.ds_page_header
            eyebrow={eyebrow(@request)}
            title={consent_title(@request)}
            description={consent_text(@request)}
            class="is-compact"
          >
          </.ds_page_header>

          <.ds_card class="ds-settings-card">
            <div id="poppy-consent-client">
              <div :if={@known} id="poppy-consent-known" class="consent-client is-known">
                <img src={@known.logo} alt="" width="48" height="48" class="consent-client-logo" />
                <div class="consent-client-text">
                  <span class="consent-client-name">
                    {@known.name}
                    <span class="ds-badge consent-badge is-recognized">
                      <.icon name="hero-check-badge" class="size-3.5" /> Recognized app
                    </span>
                  </span>
                  <span class="consent-client-meta" translate="no">
                    {@known.publisher} · {client_host(@request.client)}
                  </span>
                </div>
              </div>

              <div :if={!@known} class="consent-client">
                <span class="consent-client-logo is-unknown">
                  <.icon name="hero-question-mark-circle" class="size-6" />
                </span>
                <div class="consent-client-text">
                  <span class="consent-client-name">
                    {@request.client.client_name || "(no name)"}
                    <span class="ds-badge consent-badge">Not verified</span>
                  </span>
                  <span :if={!registered?(@request.client)} class="consent-client-meta">
                    Calls itself this. Verified domain:
                    <strong translate="no">{client_host(@request.client)}</strong>
                  </span>
                  <span :if={registered?(@request.client)} class="consent-client-meta">
                    Calls itself this. No verified domain. This app registered itself, so
                    Reviews can't tell who runs it.
                  </span>
                </div>
              </div>

              <dl class="poppy-facts">
                <div>
                  <dt>Returns you to</dt>
                  <dd>
                    <strong translate="no">{redirect_host(@request.redirect_uri)}</strong>
                    <code translate="no">{@request.redirect_uri}</code>
                  </dd>
                </div>
                <div>
                  <dt>Client ID</dt>
                  <dd translate="no"><code>{@request.client.client_id}</code></dd>
                </div>
              </dl>
            </div>

            <p
              :if={Gatekeep.Clients.loopback_redirect?(@request.redirect_uri)}
              id="poppy-consent-loopback"
              class="poppy-consent-note"
            >
              This sends you back to an app on this computer. Allow it only if you started
              connecting it yourself, just now.
            </p>

            <div
              :if={@identities == []}
              id="poppy-consent-no-agents"
              class="ds-settings-empty-inline"
            >
              <.icon name="hero-cpu-chip" class="size-4" />
              <span>
                You have no agent identities yet. Allowing creates one for this app.
              </span>
            </div>

            <form
              id="poppy-consent-form"
              action={~p"/oauth/authorize"}
              method="post"
              class="poppy-consent-form"
            >
              <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
              <input
                :for={{name, value} <- @auth_params}
                :key={name}
                type="hidden"
                name={name}
                value={value}
              />

              <fieldset id="poppy-consent-identity">
                <legend>Act as</legend>
                <label :for={identity <- @identities} :key={identity.id}>
                  <input
                    type="radio"
                    name="identity_id"
                    value={identity.id}
                    checked={@selected == to_string(identity.id)}
                    id={"poppy-identity-#{identity.id}"}
                  />
                  {identity.display_name} <span translate="no">(@{identity.handle})</span>
                </label>
                <label for="poppy-identity-new">
                  <input
                    type="radio"
                    name="identity_id"
                    value="new"
                    checked={@selected == "new"}
                    id="poppy-identity-new"
                  /> New agent identity
                </label>
                <div id="poppy-new-identity" class="poppy-new-identity">
                  <.input
                    field={@new_identity[:display_name]}
                    id="poppy-new-identity-name"
                    type="text"
                    label="Agent name"
                    autocomplete="off"
                  />
                  <.input
                    field={@new_identity[:handle]}
                    id="poppy-new-identity-handle"
                    type="text"
                    label="Handle"
                    autocomplete="off"
                    autocapitalize="none"
                    spellcheck="false"
                  />
                </div>
              </fieldset>

              <fieldset id="poppy-consent-scopes" class="consent-scopes">
                <legend>What it may do</legend>
                <div :if={read_scopes(@request) != []} class="consent-scope-group is-read">
                  <p class="consent-scope-group-title">
                    <.icon name="hero-eye" class="size-4" /> Read <span>Always included</span>
                  </p>
                  <div :for={scope <- read_scopes(@request)} :key={scope} class="consent-scope">
                    <input type="hidden" name="granted_scopes[]" value={scope} />
                    <.icon name="hero-check" class="size-4 consent-scope-mark" />
                    <.scope_text scope={scope} titles={@scope_titles} scopes={@scopes} />
                  </div>
                </div>
                <div :if={write_scopes(@request) != []} class="consent-scope-group is-write">
                  <p class="consent-scope-group-title">
                    <.icon name="hero-pencil-square" class="size-4" /> Write
                    <span>As the agent you pick</span>
                  </p>
                  <label
                    :for={scope <- write_scopes(@request)}
                    :key={scope}
                    class="consent-scope"
                    for={"poppy-scope-#{scope}"}
                  >
                    <input
                      type="checkbox"
                      name="granted_scopes[]"
                      value={scope}
                      id={"poppy-scope-#{scope}"}
                      checked
                    />
                    <.scope_text scope={scope} titles={@scope_titles} scopes={@scopes} />
                  </label>
                </div>
              </fieldset>

              <p class="poppy-consent-note">{text(@request).note}</p>

              <div class="poppy-consent-actions">
                <.ds_button
                  id="poppy-consent-approve"
                  type="submit"
                  name="decision"
                  value="approve"
                  variant="primary"
                  icon="hero-check"
                >
                  Allow
                </.ds_button>
                <.ds_button
                  id="poppy-consent-deny"
                  type="submit"
                  name="decision"
                  value="deny"
                  icon="hero-x-mark"
                >
                  Deny
                </.ds_button>
              </div>
            </form>
          </.ds_card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :scope, :string, required: true
  attr :titles, :map, required: true
  attr :scopes, :map, required: true

  defp scope_text(assigns) do
    ~H"""
    <span class="consent-scope-text">
      <span class="consent-scope-title">{@titles[@scope] || @scope}</span>
      <span :if={@titles[@scope]} class="consent-scope-desc">{@scopes[@scope]}</span>
      <code translate="no" class="consent-scope-name">{@scope}</code>
    </span>
    """
  end

  # A scope that only reads is part of every grant that asks for it; the
  # page lets the owner leave out writes.
  defp read_scopes(request), do: Enum.filter(request.scopes, &String.ends_with?(&1, ":read"))
  defp write_scopes(request), do: request.scopes -- read_scopes(request)

  def invalid_request(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="poppy-invalid-request" class="l-page design-page">
        <div class="design-main is-settings">
          <.ds_empty_state
            icon="hero-exclamation-triangle"
            title={@page_title}
            body={reason_text(@reason)}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp reason_text(:invalid_redirect_uri),
    do: "The agent asked to return you to an address it didn't register. Nothing was shared."

  defp reason_text(:signed_out), do: "Your Reviews session ended. Open the sign-in link again."

  defp reason_text(:invalid_request),
    do: "The app sent a sign-in request Reviews can't accept. Nothing was shared."

  defp reason_text(_),
    do: "Reviews couldn't verify the agent that sent this link. Nothing was shared."

  defp text(request) do
    module = Reviews.OAuth.resource_module(request.resource)
    module.consent_text(client_label(request.client, known_client(module, request.client)))
  end

  @doc """
  The client the requested resource recognizes (`known_client/1`), or nil.
  Only a client named by its metadata document's URL can be recognized.
  """
  def known_client(request) do
    known_client(Reviews.OAuth.resource_module(request.resource), request.client)
  end

  defp known_client(module, %{kind: kind, client_id: client_id}) when kind != :registered do
    if function_exported?(module, :known_client, 1), do: module.known_client(client_id)
  end

  defp known_client(_module, _client), do: nil

  @doc "Short titles for the requested resource's scopes (`scope_titles/0`)."
  def scope_titles(request) do
    module = Reviews.OAuth.resource_module(request.resource)
    if function_exported?(module, :scope_titles, 0), do: module.scope_titles(), else: %{}
  end

  defp sign_in_text(request), do: text(request).sign_in
  defp eyebrow(request), do: text(request).eyebrow
  defp consent_title(request), do: text(request).title
  defp consent_text(request), do: text(request).description

  defp registered?(client), do: client.kind == :registered

  # A recognized client by its name; a registered client, which has no
  # verified domain, by what it calls itself; any other by its domain.
  defp client_label(_client, %{name: name}), do: name

  defp client_label(%{kind: :registered} = client, nil),
    do: "An app that calls itself #{client.client_name || "(no name)"}"

  defp client_label(client, nil), do: client_host(client)

  defp client_host(%{client_id: client_id}), do: URI.parse(client_id).host

  defp redirect_host(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      %URI{scheme: scheme} -> "#{scheme}: (an app on this device)"
    end
  end
end
