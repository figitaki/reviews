defmodule ReviewsWeb.OAuthHTML do
  @moduledoc """
  Pages for the OAuth issuer: sign in, consent, and an invalid request.

  The consent page names the client by the domain that published its
  metadata document (its `client_id` host) and shows its `client_name` only
  as what it calls itself, so an unverified name is never shown as verified.
  A client registered through dynamic client registration has no verified
  domain, so the page says so and leads with the host it sends you back to.

  The wording comes from the requested resource
  (`c:Reviews.OAuth.Resource.consent_text/1`).
  """
  use ReviewsWeb, :html

  def sign_in(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="poppy-sign-in" class="l-page design-page">
        <div class="design-main is-settings">
          <.ds_page_header
            eyebrow={eyebrow(@request)}
            title="Sign in to continue"
            description={sign_in_text(@request)}
            class="is-compact"
          >
            <:actions>
              <.link
                id="poppy-sign-in-github"
                href={~p"/auth/github?#{[return_to: @return_to]}"}
                class="ds-button is-primary"
              >
                Sign in with GitHub
              </.link>
            </:actions>
          </.ds_page_header>
        </div>
      </main>
    </Layouts.app>
    """
  end

  def consent(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="poppy-consent" class="l-page design-page">
        <div class="design-main is-settings">
          <.ds_page_header
            eyebrow={eyebrow(@request)}
            title={consent_title(@request)}
            description={consent_text(@request)}
            class="is-compact"
          >
          </.ds_page_header>

          <.ds_card class="ds-settings-card">
            <dl id="poppy-consent-client" class="poppy-facts">
              <div :if={!@request.client.registered}>
                <dt>Verified domain</dt>
                <dd translate="no">{client_host(@request.client)}</dd>
              </div>
              <div :if={@request.client.registered}>
                <dt>Verified domain</dt>
                <dd>
                  None. This app registered itself, so Reviews can't tell who runs it.
                </dd>
              </div>
              <div>
                <dt>Calls itself</dt>
                <dd>
                  {@request.client.client_name || "(no name)"}
                  <span class="ds-badge">Not verified</span>
                </dd>
              </div>
              <div>
                <dt>Client ID</dt>
                <dd translate="no"><code>{@request.client.client_id}</code></dd>
              </div>
              <div>
                <dt>Returns you to</dt>
                <dd>
                  <strong translate="no">{redirect_host(@request.redirect_uri)}</strong>
                  <code translate="no">{@request.redirect_uri}</code>
                </dd>
              </div>
            </dl>

            <p
              :if={Reviews.OAuth.Clients.loopback_redirect?(@request.redirect_uri)}
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
                    class="ds-input"
                  />
                  <.input
                    field={@new_identity[:handle]}
                    id="poppy-new-identity-handle"
                    type="text"
                    label="Handle"
                    autocomplete="off"
                    autocapitalize="none"
                    spellcheck="false"
                    class="ds-input"
                  />
                </div>
              </fieldset>

              <fieldset id="poppy-consent-scopes">
                <legend>Permissions</legend>
                <label :for={scope <- @request.scopes} :key={scope}>
                  <input type="checkbox" name="granted_scopes[]" value={scope} checked />
                  <span><code>{scope}</code>: {@scopes[scope]}</span>
                </label>
              </fieldset>

              <p class="poppy-consent-note">{text(@request).note}</p>

              <div class="poppy-consent-actions">
                <button
                  id="poppy-consent-approve"
                  type="submit"
                  name="decision"
                  value="approve"
                  class="ds-button is-primary"
                >
                  Allow
                </button>
                <button
                  id="poppy-consent-deny"
                  type="submit"
                  name="decision"
                  value="deny"
                  class="ds-button"
                >
                  Deny
                </button>
              </div>
            </form>
          </.ds_card>
        </div>
      </main>
    </Layouts.app>
    """
  end

  def invalid_request(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="poppy-invalid-request" class="l-page design-page">
        <div class="design-main is-settings">
          <.ds_empty_state
            icon="hero-exclamation-triangle"
            title={@page_title}
            body={reason_text(@reason)}
          />
        </div>
      </main>
    </Layouts.app>
    """
  end

  defp reason_text(:invalid_redirect_uri),
    do: "The agent asked to return you to an address it didn't register. Nothing was shared."

  defp reason_text(:signed_out), do: "Your Reviews session ended. Open the sign-in link again."

  defp reason_text(:bad_request),
    do: "The app sent a sign-in request Reviews can't accept. Nothing was shared."

  defp reason_text(_),
    do: "Reviews couldn't verify the agent that sent this link. Nothing was shared."

  defp text(request),
    do: Reviews.OAuth.resource_for(request.provider).consent_text(client_label(request.client))

  defp sign_in_text(request), do: text(request).sign_in
  defp eyebrow(request), do: text(request).eyebrow
  defp consent_title(request), do: text(request).title
  defp consent_text(request), do: text(request).description

  # A registered client has no verified domain; name it by where it sends you.
  defp client_label(%{registered: true} = client),
    do: "An app that calls itself #{client.client_name || "(no name)"}"

  defp client_label(client), do: client_host(client)

  defp client_host(%{client_id: client_id}), do: URI.parse(client_id).host

  defp redirect_host(uri) do
    case URI.parse(uri) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      %URI{scheme: scheme} -> "#{scheme}: (an app on this device)"
    end
  end
end
