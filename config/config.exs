# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :reviews,
  ecto_repos: [Reviews.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :reviews, ReviewsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ReviewsWeb.ErrorHTML, json: ReviewsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Reviews.PubSub,
  live_view: [signing_salt: "RllUbgpY"]

# Hosted MCP endpoint (docs/MCP.md). Off unless enabled; dev and test enable
# it, and prod reads MCP_ENABLED / MCP_WRITES_ENABLED in runtime.exs.
config :reviews, :mcp, enabled: false, writes_enabled: false, allowed_hosts: :localhost

# MCP connectors Reviews recognizes (`Reviews.MCPAuth.known_connector/1`). The
# consent page shows their name and logo as verified, and `/mcp` accepts
# requests from their origins. Add a client by its client metadata document URL.
config :reviews, Reviews.MCPAuth,
  connectors: [
    %{
      client_id: "https://claude.ai/oauth/mcp-oauth-client-metadata",
      name: "Claude",
      publisher: "Anthropic",
      logo: "/images/connectors/claude.png",
      origins: ["https://claude.ai", "https://claude.com"]
    },
    %{
      client_id: "https://chatgpt.com/oauth/client.json",
      name: "ChatGPT",
      publisher: "OpenAI",
      logo: "/images/connectors/chatgpt.png",
      origins: ["https://chatgpt.com"]
    }
  ]

# Design catalog at /design (ReviewsWeb.DesignLive). Off unless enabled; dev
# and test enable it, and prod reads DESIGN_CATALOG in runtime.exs.
config :reviews, :design_catalog, false

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  reviews: [
    args:
      ~w(js/app.js js/theme.js js/diffs_worker.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Ueberauth: GitHub OAuth strategy. Client id/secret loaded at runtime (see runtime.exs).
config :ueberauth, Ueberauth,
  json_library: JSON,
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "read:user user:email"]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  reviews: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Elixir's built-in JSON module for Phoenix, Postgrex (jsonb columns) and Ueberauth.
config :phoenix, :json_library, JSON

# Keep OAuth secrets out of request logs. Phoenix already filters "password";
# the rest are sign-in values (Reviews.OAuth).
config :phoenix, :filter_parameters, [
  "password",
  "client_assertion",
  "code",
  "code_verifier",
  "device_code",
  "user_code",
  "refresh_token",
  "token"
]

# The OAuth issuer (Reviews.OAuth, on gatekeep). Each API that accepts its
# tokens is a Reviews.OAuth.Resource listed here. A request without `resource`
# or a scope it recognizes goes to the default. The other keys are
# Gatekeep.Config options. Registered clients keep the `rvc_` IDs Reviews
# handed out before gatekeep, and DPoP proofs use ES256, as Session JWTs do.
config :reviews, Reviews.OAuth,
  # Reviews.OAuth.CLI is `reviews login`: the device authorization grant,
  # approved at /device, for the CLI's own client only.
  resources: [Reviews.Poppy, Reviews.OAuth.CLI, Reviews.MCPAuth],
  default_resource: Reviews.Poppy,
  device_verification_uri: "/device",
  storage: {Gatekeep.Storage.Ecto, repo: Reviews.Repo},
  consent: ReviewsWeb.OAuthController,
  registered_client_prefix: "rvc_",
  dpop_signing_algs: ["ES256"],
  # ChatGPT addresses its client assertions to the token endpoint, not the issuer.
  token_endpoint_audience_clients: ["https://chatgpt.com/oauth/client.json"]

# Poppy requests go through the Turnkey adapter, which adds what it verified
# about Turnkey-hosted agents and otherwise is the Poppy adapter. The agent
# host comes from Turnkey's draft Personal Agent Protocol guide and is
# provisional until Turnkey ships it (see Reviews.Turnkey).
config :reviews, Reviews.Poppy, adapter: Reviews.Turnkey.Adapter
config :reviews, Reviews.Turnkey, agent_hosts: ["id.turnkey.com"]

config :postgrex, :json_library, JSON

# Code storage: disabled by default. The code.storage adapter and its
# credentials are selected via env vars in config/runtime.exs.
config :reviews, Reviews.CodeStorage,
  adapter: Reviews.CodeStorage.Disabled,
  policy: :optional,
  supported_object_formats: ["sha1"],
  max_upload_bytes: 536_870_912,
  snapshot_ttl_seconds: 900,
  upload_token_ttl_seconds: 900

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
