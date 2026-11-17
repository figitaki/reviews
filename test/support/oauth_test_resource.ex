defmodule Reviews.OAuthTestResource do
  @moduledoc """
  An `Reviews.OAuth.Resource` for tests at `/api/test`: public clients and
  clients with keys, rotating refresh tokens, and two scopes. A request with
  no scope gets both.
  """
  @behaviour Reviews.OAuth.Resource

  @scopes %{"test:read" => "Read test things.", "test:write" => "Write test things."}
  @scope_order ["test:read", "test:write"]

  @impl true
  def provider, do: "test"
  @impl true
  def resource, do: Reviews.OAuth.issuer() <> "/api/test"
  @impl true
  def enabled?, do: Application.get_env(:reviews, __MODULE__, enabled: true)[:enabled]
  @impl true
  def scopes, do: @scopes
  @impl true
  def scope_names, do: @scope_order
  @impl true
  def client_auth_methods, do: ["none", "private_key_jwt"]
  @impl true
  def rotate_refresh_tokens?, do: true

  @impl true
  def parse_scopes(nil), do: {:ok, @scope_order}

  def parse_scopes(scope) when is_binary(scope) do
    scopes = scope |> String.split(" ", trim: true) |> Enum.uniq()

    cond do
      scopes == [] ->
        {:ok, @scope_order}

      Enum.all?(scopes, &Map.has_key?(@scopes, &1)) ->
        {:ok, Enum.filter(@scope_order, &(&1 in scopes))}

      true ->
        :error
    end
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

  @impl true
  def protected_resource_metadata, do: %{resource_name: "Test API"}

  defmodule KeysOnly do
    @moduledoc """
    A second test resource at `/api/keys`: only clients with keys, no
    refresh rotation, one scope, and no default scope.
    """
    @behaviour Reviews.OAuth.Resource

    @impl true
    def provider, do: "keys"
    @impl true
    def resource, do: Reviews.OAuth.issuer() <> "/api/keys"
    @impl true
    def enabled?, do: true
    @impl true
    def scopes, do: %{"keys:write" => "Write with keys."}
    @impl true
    def scope_names, do: ["keys:write"]
    @impl true
    def client_auth_methods, do: ["private_key_jwt"]
    @impl true
    def rotate_refresh_tokens?, do: false

    @impl true
    def parse_scopes(scope) when is_binary(scope) do
      scopes = scope |> String.split(" ", trim: true) |> Enum.uniq()
      if scopes != [] and scopes -- ["keys:write"] == [], do: {:ok, scopes}, else: :error
    end

    def parse_scopes(_), do: :error

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
