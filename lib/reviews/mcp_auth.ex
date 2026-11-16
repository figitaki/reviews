defmodule Reviews.MCPAuth do
  @moduledoc """
  OAuth for the hosted MCP endpoint (`/mcp`), so connectors such as Claude
  and ChatGPT can sign in (issue #109).

  This is `/mcp`'s `Reviews.OAuth.Resource`: its identifier (RFC 8707), its
  scopes, and how its clients sign in. MCP connectors may be public clients
  (`none`, PKCE only), and their refresh tokens rotate. The owner approves a
  connector on the issuer's consent page and picks which of their agent
  identities it acts as. The approval is an `Reviews.Accounts.IdentityLink`
  with provider `"mcp"`, so its tokens only work at `/mcp`.

  Reviews API tokens keep working at `/mcp` unchanged.
  """
  @behaviour Reviews.OAuth.Resource

  @provider "mcp"

  @scopes %{
    "reviews:read" => "Read reviews your account owns: packets, diffs, and comment threads.",
    "reviews:write" => "Create reviews and push new revisions, as the identity you choose.",
    "threads:write" =>
      "Post comments and replies and resolve or reopen threads, as the identity you choose."
  }

  # The order the consent page and metadata list them in.
  @scope_order ["reviews:read", "reviews:write", "threads:write"]

  @doc "Whether `/mcp` is on (`config :reviews, :mcp, enabled: true`)."
  @impl true
  def enabled?, do: Keyword.get(Application.get_env(:reviews, :mcp, []), :enabled, false)

  @impl true
  def provider, do: @provider
  @impl true
  def scopes, do: @scopes
  @impl true
  def scope_names, do: @scope_order

  @doc "The MCP endpoint's canonical URL, the audience of its tokens."
  @impl true
  def resource, do: Reviews.OAuth.issuer() <> "/mcp"

  @doc "Where the endpoint's protected resource metadata (RFC 9728) is served."
  def resource_metadata_url,
    do: Reviews.OAuth.issuer() <> "/.well-known/oauth-protected-resource/mcp"

  @impl true
  def client_auth_methods, do: ["none", "private_key_jwt"]

  @impl true
  def rotate_refresh_tokens?, do: true

  @impl true
  def protected_resource_metadata,
    do: %{resource_name: "Reviews", bearer_methods_supported: ["header"]}

  @impl true
  def consent_text(client_label) do
    %{
      eyebrow: "Connect an app",
      title: "Let this app use Reviews for you?",
      sign_in:
        "#{client_label} wants to use your Reviews account. Sign in with GitHub to choose what it may do.",
      description:
        "#{client_label} wants to read your reviews and post as one of your Reviews agents. Continue only if you just asked it to connect.",
      note:
        "It can use only the reviews your account owns. What it posts shows as the agent you pick, never as you. You can disconnect it at any time in Settings."
    }
  end

  @doc "Parses a requested scope. Missing means every MCP scope."
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

  def parse_scopes(_), do: :error
end
