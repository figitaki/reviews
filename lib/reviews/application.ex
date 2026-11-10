defmodule Reviews.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ReviewsWeb.Telemetry,
        Reviews.Repo,
        {DNSCluster, query: Application.get_env(:reviews, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Reviews.PubSub}
      ] ++
        sweeper_children() ++
        [
          # Start to serve requests, typically the last entry
          ReviewsWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Reviews.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Off in the test env; tests drive Sweeper.sweep/1 directly.
  defp sweeper_children do
    if Application.get_env(:reviews, Reviews.CodeStorage.Sweeper, [])[:enabled] == false do
      []
    else
      [Reviews.CodeStorage.Sweeper]
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ReviewsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
