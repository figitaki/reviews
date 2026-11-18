defmodule Reviews.OAuthTestResource do
  @moduledoc """
  An `Reviews.OAuth.Resource` for tests at `/api/test`: public clients and
  clients with keys, rotating refresh tokens, and two scopes. A request with
  no scope gets both. `config :reviews, Reviews.OAuthTestResource, enabled:
  false` turns it off.
  """
  @behaviour Reviews.OAuth.Resource

  @impl true
  def options do
    [
      id: Reviews.OAuth.issuer() <> "/api/test",
      name: "Test API",
      scopes: [{"test:read", "Read test things."}, {"test:write", "Write test things."}],
      client_auth_methods: ["none", "private_key_jwt"],
      rotate_refresh_tokens: true,
      enabled: Application.get_env(:reviews, __MODULE__, enabled: true)[:enabled]
    ]
  end

  @impl true
  def consent_text(client_label) do
    %{
      eyebrow: "Connect a test app",
      title: "Let this test app in?",
      sign_in: "#{client_label} wants to use the test API. Sign in with GitHub.",
      description: "#{client_label} wants to use the test API as one of your agents.",
      note: "Test resource."
    }
  end

  defmodule KeysOnly do
    @moduledoc """
    A second test resource at `/api/keys`: only clients with keys, no
    refresh rotation, one scope, and no default scope.
    """
    @behaviour Reviews.OAuth.Resource

    @impl true
    def options do
      [
        id: Reviews.OAuth.issuer() <> "/api/keys",
        scopes: [{"keys:write", "Write with keys."}],
        default_scopes: [],
        client_auth_methods: ["private_key_jwt"],
        rotate_refresh_tokens: false
      ]
    end

    @impl true
    def consent_text(client_label) do
      %{
        eyebrow: "Connect an agent",
        title: "Let this agent act for you?",
        sign_in: "#{client_label} wants to act as one of your agents.",
        description: "#{client_label} wants to write as one of your agents.",
        note: "Keys resource."
      }
    end

    @impl true
    def authorization_server_metadata, do: %{keys_resource_extra: true}
  end
end
