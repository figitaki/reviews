import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :reviews, Reviews.Repo,
  username: System.get_env("POSTGRES_USER", "warbler"),
  password: System.get_env("POSTGRES_PASSWORD", ""),
  database: "reviews_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

if System.get_env("POSTGRES_HOST") do
  config :reviews, Reviews.Repo, hostname: System.get_env("POSTGRES_HOST")
else
  config :reviews, Reviews.Repo, socket_dir: "/tmp"
end

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :reviews, ReviewsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "PksNuEADSq2cFj3rPjGzuMlw2ulffcTg5IHJLaFhVcq8wWgjFfUr/EhTVD4cpvRl",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
