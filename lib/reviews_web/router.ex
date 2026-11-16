defmodule ReviewsWeb.Router do
  use ReviewsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ReviewsWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" =>
        "base-uri 'self'; frame-ancestors 'self'; script-src 'self'; object-src 'none';"
    }

    plug ReviewsWeb.Plugs.FetchCurrentUser
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_authenticated do
    plug ReviewsWeb.Plugs.RequireApiToken
  end

  # JSON-only OAuth endpoints: nothing here should ever load or frame.
  pipeline :oauth_endpoint do
    plug :put_secure_browser_headers, %{
      "content-security-policy" => "default-src 'none'; frame-ancestors 'none'"
    }

    plug :put_oauth_cors
  end

  # Discovery documents are public; browser-based clients, such as the MCP
  # Inspector, read them from another origin.
  pipeline :oauth_discovery do
    plug :put_oauth_cors
  end

  pipeline :review_content do
    plug :put_review_robots_header
  end

  scope "/", ReviewsWeb do
    pipe_through :browser

    live "/", HomeLive, :index
    live "/settings", SettingsLive, :edit
  end

  scope "/", ReviewsWeb do
    pipe_through [:browser, :review_content]

    live "/r/:slug", ReviewLive, :show
    live "/r/:slug/changes", ReviewLive, :changes
  end

  # The OAuth issuer (Reviews.OAuth): discovery, authorization, and tokens.
  # The CLI's bearer-token API under /api/v1 is unchanged.
  scope "/", ReviewsWeb do
    pipe_through :oauth_discovery

    get "/.well-known/oauth-authorization-server", OAuthDiscoveryController, :authorization_server
    get "/.well-known/oauth-protected-resource", OAuthDiscoveryController, :protected_resource

    get "/.well-known/oauth-protected-resource/*path",
        OAuthDiscoveryController,
        :protected_resource

    options "/.well-known/*path", OAuthDiscoveryController, :authorization_server
  end

  scope "/oauth", ReviewsWeb do
    pipe_through :browser

    get "/authorize", OAuthController, :authorize
    post "/authorize", OAuthController, :approve
  end

  scope "/oauth", ReviewsWeb do
    pipe_through :oauth_endpoint

    post "/token", OAuthController, :token
    post "/revoke", OAuthController, :revoke
    post "/register", OAuthController, :register
    options "/:endpoint", OAuthController, :token
  end

  # Preview sign-in relay. Before /auth/:provider, which would match /auth/relay.
  scope "/auth/relay", ReviewsWeb do
    pipe_through :browser

    get "/", AuthRelayController, :confirm
    post "/", AuthRelayController, :start
    get "/accept", AuthRelayController, :accept
  end

  scope "/auth", ReviewsWeb do
    pipe_through :browser

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
    delete "/logout", AuthController, :delete
  end

  scope "/api/v1", ReviewsWeb.Api do
    pipe_through [:api, :review_content]

    get "/reviews/:slug", ReviewController, :show
  end

  scope "/api/v1", ReviewsWeb.Api do
    pipe_through [:api, :api_authenticated]

    post "/reviews", ReviewController, :create
    post "/reviews/:slug/patchsets", PatchsetController, :create
    post "/reviews/:slug/comments", CommentController, :create
    patch "/reviews/:slug/threads/:thread_id", ThreadController, :update
    post "/reviews/:slug/sections/:section_index/decision", SectionDecisionController, :create
    get "/me", MeController, :show
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:reviews, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ReviewsWeb.Telemetry
    end
  end

  # Crawler directives only; review links remain anonymously accessible.
  defp put_review_robots_header(conn, _opts) do
    put_resp_header(conn, "x-robots-tag", "noindex, nofollow, noarchive")
  end

  # No cookies are read here, so any origin may call. A preflight ends here.
  defp put_oauth_cors(conn, _opts) do
    conn = put_resp_header(conn, "access-control-allow-origin", "*")

    if conn.method == "OPTIONS" do
      conn
      |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
      |> put_resp_header(
        "access-control-allow-headers",
        "authorization, content-type, dpop, mcp-protocol-version"
      )
      |> put_resp_header("access-control-max-age", "600")
      |> send_resp(204, "")
      |> halt()
    else
      conn
    end
  end
end
