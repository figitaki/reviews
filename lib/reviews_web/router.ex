defmodule ReviewsWeb.Router do
  use ReviewsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ReviewsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ReviewsWeb.Plugs.FetchCurrentUser
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_authenticated do
    plug ReviewsWeb.Plugs.RequireApiToken
  end

  scope "/", ReviewsWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/r/:slug", ReviewLive, :show
    live "/settings", SettingsLive, :edit
  end

  scope "/auth", ReviewsWeb do
    pipe_through :browser

    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
    delete "/logout", AuthController, :delete
  end

  scope "/api/v1", ReviewsWeb.Api do
    pipe_through :api

    get "/reviews/:slug", ReviewController, :show
  end

  scope "/api/v1", ReviewsWeb.Api do
    pipe_through [:api, :api_authenticated]

    post "/reviews", ReviewController, :create
    post "/reviews/:slug/patchsets", PatchsetController, :create
    post "/reviews/:slug/comments", CommentController, :create
    get "/me", MeController, :show
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:reviews, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/", ReviewsWeb do
      pipe_through :browser

      live "/design", DesignLive, :show
    end

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ReviewsWeb.Telemetry
    end
  end
end
