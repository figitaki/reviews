defmodule ReviewsWeb.DeviceHTML do
  @moduledoc """
  Pages of the CLI sign-in (`ReviewsWeb.DeviceController`). The
  confirmation repeats the code and asks the person to check it against
  their terminal, since anyone can start a sign-in and send someone the link.
  """
  use ReviewsWeb, :html

  def sign_in(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="device-sign-in" class="l-page design-page">
        <div class="design-main is-settings">
          <.ds_page_header
            eyebrow="Reviews CLI"
            title="Sign in to continue"
            description="Sign in with GitHub, then enter the code your terminal shows."
            class="is-compact"
          >
            <:actions>
              <.link
                id="device-sign-in-github"
                href={~p"/auth/github?#{[return_to: @return_to]}"}
                class="ds-button is-primary"
              >
                Sign in with GitHub
              </.link>
            </:actions>
          </.ds_page_header>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def entry(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="device-entry" class="l-page design-page">
        <div class="design-main is-settings">
          <.ds_page_header
            eyebrow="Reviews CLI"
            title="Enter the code from your terminal"
            description="reviews login shows an 8-letter code in your terminal. Enter it here, then choose who the CLI acts as."
            class="is-compact"
          />

          <.ds_card class="ds-settings-card">
            <p :if={@error} id="device-error" class="poppy-consent-note" role="alert">
              {error_text(@error)}
            </p>

            <form id="device-entry-form" action={~p"/device"} method="post" class="ds-settings-form">
              <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
              <div>
                <label for="device-user-code">Code</label>
                <input
                  id="device-user-code"
                  name="user_code"
                  type="text"
                  class="ds-input"
                  placeholder="WDJB-MJHT"
                  autocomplete="off"
                  autocapitalize="characters"
                  spellcheck="false"
                  maxlength="20"
                  required
                  autofocus
                />
              </div>
              <button id="device-entry-submit" type="submit" class="ds-button is-primary">
                Continue
              </button>
            </form>
          </.ds_card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def confirm(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="device-confirm" class="l-page design-page">
        <div class="design-main is-settings">
          <.ds_page_header
            eyebrow="Reviews CLI"
            title="Sign in to the Reviews CLI?"
            description="The CLI will push reviews, comment, reply, resolve threads, and decide sections as the identity you choose."
            class="is-compact"
          />

          <.ds_card class="ds-settings-card">
            <dl class="poppy-facts">
              <div>
                <dt>Code</dt>
                <dd id="device-confirm-code" translate="no">
                  <strong><code>{@request.user_code}</code></strong>
                </dd>
              </div>
            </dl>

            <p id="device-confirm-warning" class="poppy-consent-note">
              Check that this code matches the one in your terminal. Allow it only if you ran
              <code>reviews login</code>
              yourself, just now. If someone sent you this link, deny it.
            </p>

            <form
              id="device-confirm-form"
              action={~p"/device/decide"}
              method="post"
              class="poppy-consent-form"
            >
              <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
              <input type="hidden" name="user_code" value={@request.user_code} />

              <fieldset id="device-identity">
                <legend>Act as</legend>
                <label :for={{identity, index} <- Enum.with_index(@identities)} :key={identity.id}>
                  <input
                    type="radio"
                    name="identity_id"
                    value={identity.id}
                    checked={index == 0}
                    id={"device-identity-#{identity.id}"}
                  />
                  {identity.display_name} <span translate="no">(@{identity.handle})</span>
                  <span :if={identity.kind == "human"} class="ds-badge">You</span>
                  <span :if={identity.kind == "agent"} class="ds-badge">Agent</span>
                </label>
              </fieldset>
              <div class="poppy-consent-actions">
                <button
                  id="device-approve"
                  type="submit"
                  name="decision"
                  value="approve"
                  class="ds-button is-primary"
                >
                  Allow
                </button>
                <button id="device-deny" type="submit" name="decision" value="deny" class="ds-button">
                  Deny
                </button>
              </div>
            </form>
          </.ds_card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def done(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="device-done" class="l-page design-page">
        <div class="design-main is-settings">
          <div :if={@outcome == :approved} id="device-approved">
            <.ds_empty_state
              icon="hero-check-circle"
              title="The CLI is signed in"
              body="Go back to your terminal. You can sign it out at any time under CLI sign-ins in Settings."
            />
          </div>
          <div :if={@outcome == :denied} id="device-denied">
            <.ds_empty_state
              icon="hero-x-circle"
              title="Sign-in denied"
              body="The CLI was not signed in. Nothing was shared."
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp error_text(:expired_user_code),
    do: "That code expired. Run reviews login again for a new one."

  defp error_text(:too_many_attempts),
    do: "Too many wrong codes. Wait 15 minutes, then try again."

  defp error_text(_),
    do: "That code isn't valid. Check it against your terminal, or run reviews login again."
end
