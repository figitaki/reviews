defmodule Reviews.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ReviewsWeb.Telemetry,
      Reviews.Repo,
      Reviews.RateLimiter,
      {DNSCluster, query: Application.get_env(:reviews, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Reviews.PubSub},
      # Before the endpoint, so /mcp never sees a stopped server.
      ReviewsWeb.MCP.Server,
      # The OAuth issuer's client metadata cache, after the repo.
      Reviews.OAuth.Issuer,
      # Wrong-code counts for the CLI sign-in page (/device).
      Reviews.OAuth.DeviceAttempts,
      # Start to serve requests, typically the last entry
      ReviewsWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Reviews.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ReviewsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
