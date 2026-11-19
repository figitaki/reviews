defmodule Reviews.MCPAuth do
  @moduledoc """
  OAuth for the hosted MCP endpoint (`/mcp`), so connectors such as Claude
  and ChatGPT can sign in (issue #109).

  This is `/mcp`'s `Reviews.OAuth.Resource`: its identifier (RFC 8707), its
  scopes, and how its clients sign in. MCP connectors may be public clients
  (`none`, PKCE only, as Claude's client metadata document asks) or use
  `private_key_jwt` (ChatGPT), and their refresh tokens rotate. The owner
  approves a connector on the issuer's consent page and picks which of their
  agent identities it acts as, so its tokens act as that agent, never as the
  person, and work only at `/mcp`.

  The scopes match `Reviews.Policy`: each write needs the scope Policy names
  for it. Reviews API tokens keep working at `/mcp` with every scope.
  """
  @behaviour Reviews.OAuth.Resource

  # In the order the consent page and metadata list them: {name, title,
  # description}. The consent page groups `:read` scopes apart from the rest.
  @scopes [
    {"reviews:read", "Read reviews",
     "See reviews, their packets and diffs, and comment threads."},
    {"reviews:write", "Create and update reviews",
     "Push new reviews, and new revisions of reviews your account owns."},
    {"comments:write", "Post comments", "Comment on reviews and reply to threads."},
    {"threads:write", "Resolve threads",
     "Resolve or reopen threads on your reviews and threads your account started."}
  ]

  @doc "Whether `/mcp` is on (`config :reviews, :mcp, enabled: true`)."
  def enabled?, do: Keyword.get(Application.get_env(:reviews, :mcp, []), :enabled, false)

  @doc "Every scope name, in order."
  def scope_names, do: Enum.map(@scopes, &elem(&1, 0))

  @impl true
  def scope_titles, do: Map.new(@scopes, fn {name, title, _} -> {name, title} end)

  @doc """
  The connector Reviews recognizes by this `client_id`, from
  `config :reviews, Reviews.MCPAuth, connectors: [...]`: its `:name`,
  `:publisher`, `:logo` and `:origins`. Nil for any other client.
  """
  @impl true
  def known_client(client_id), do: Enum.find(connectors(), &(&1.client_id == client_id))

  @doc "The origins of every known connector, which `/mcp` accepts."
  def connector_origins, do: Enum.flat_map(connectors(), & &1.origins)

  @doc "Every known connector, in config order."
  def connectors,
    do: :reviews |> Application.get_env(__MODULE__, []) |> Keyword.get(:connectors, [])

  @doc "The MCP endpoint's canonical URL, the audience of its tokens."
  def resource, do: Reviews.OAuth.issuer() <> "/mcp"

  @doc "Where the endpoint's protected resource metadata (RFC 9728) is served."
  def resource_metadata_url,
    do: Reviews.OAuth.issuer() <> "/.well-known/oauth-protected-resource/mcp"

  @impl true
  def options do
    [
      id: resource(),
      name: "Reviews",
      scopes: Enum.map(@scopes, fn {name, _, description} -> {name, description} end),
      client_auth_methods: ["none", "private_key_jwt"],
      rotate_refresh_tokens: true,
      enabled: enabled?(),
      metadata: %{"resource_name" => "Reviews", "bearer_methods_supported" => ["header"]}
    ]
  end

  @impl true
  def consent_text(client_label) do
    %{
      eyebrow: "Connect an app",
      title: "Connect to Reviews?",
      sign_in:
        "#{client_label} wants to use your Reviews account. Sign in with GitHub to choose what it may do.",
      description: "Continue only if you just asked #{client_label} to connect.",
      note:
        "What it posts shows as the agent you pick, never as you. You can disconnect it at any time in Settings."
    }
  end
end
