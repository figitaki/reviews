defmodule Reviews.OAuth.CLI do
  @moduledoc """
  The CLI API (`/api/v1`) as a resource of the Reviews issuer, for
  `reviews login`.

  The CLI signs in with the device authorization grant (RFC 8628): it shows
  a short code, and the person enters it at `/device` on any device
  (`ReviewsWeb.DeviceController`). Only the Reviews CLI's own client,
  `reviews-cli`, may get these tokens (`allowed_clients`), and it may use no
  other grant, so no other app can ask for them.

  Unlike every other resource, these tokens act as the person's **human**
  identity, as the API tokens minted in Settings do: the CLI is the person
  at their terminal, not an agent acting for them. That is why the tokens
  are limited to this one client and this one resource, and why other
  resources refuse grants whose subject is a human identity
  (`Reviews.OAuth.authenticate_access_token/2`).

  Refresh tokens rotate; each `reviews login` is one grant, which Settings
  lists under "CLI sign-ins" and can revoke.
  """
  @behaviour Reviews.OAuth.Resource

  @client_id "reviews-cli"
  @scope "cli"

  @doc "The client ID of the Reviews CLI."
  def client_id, do: @client_id

  @doc "The resource identifier: the CLI API's URL."
  def id, do: Reviews.OAuth.issuer() <> "/api/v1"

  @doc "The pre-registered client of the CLI, a `Gatekeep.Config` `:clients` entry."
  def client do
    [
      client_id: @client_id,
      client_name: "Reviews CLI",
      public: true,
      grant_types: [Gatekeep.DeviceAuthorization.grant_type(), "refresh_token"],
      # Only the CLI API's scope, so it can't ask any other resource for tokens.
      scopes: [@scope]
    ]
  end

  @impl true
  def options do
    [
      id: id(),
      name: "Reviews CLI API",
      scopes: [
        {@scope, "Push reviews, comment, reply, resolve threads, and decide sections as you."}
      ],
      client_auth_methods: ["none"],
      allowed_clients: [@client_id]
    ]
  end

  # The CLI never reaches the consent page: it has no authorization code
  # grant. The device page has its own text.
  @impl true
  def consent_text(_client_label) do
    %{
      eyebrow: "Reviews CLI",
      title: "Sign in to the Reviews CLI?",
      sign_in: "Sign in with GitHub to continue.",
      description: "The Reviews CLI wants to act as you.",
      note: "You can sign it out at any time in Settings."
    }
  end
end
