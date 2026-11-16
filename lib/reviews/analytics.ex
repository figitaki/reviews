defmodule Reviews.Analytics do
  @moduledoc "Fixed aggregate-only export. Actor identifiers never leave PostgreSQL."
  alias Reviews.Analytics.Cache
  alias Reviews.Repo

  @external_resource Path.expand("../../priv/analytics/snapshot.sql", __DIR__)
  @query File.read!(@external_resource)

  def cached_snapshot do
    case Cache.reserve() do
      {:hit, snapshot} ->
        {:ok, snapshot}

      {:load, ticket} ->
        result = snapshot()
        Cache.store(ticket, result)
        result

      error ->
        error
    end
  end

  @doc false
  def snapshot do
    Repo.transaction(
      fn ->
        # Fixed SQL only. Bound execution and lock waits; do not log statements/results.
        Ecto.Adapters.SQL.query!(Repo, "SET LOCAL statement_timeout = '5000ms'", [], log: false)
        Ecto.Adapters.SQL.query!(Repo, "SET LOCAL lock_timeout = '500ms'", [], log: false)
        Ecto.Adapters.SQL.query!(Repo, "SET LOCAL TIME ZONE 'UTC'", [], log: false)

        %{rows: [[snapshot]]} =
          Ecto.Adapters.SQL.query!(Repo, @query, [], log: false, timeout: 6_000)

        snapshot
      end,
      log: false,
      timeout: 7_000
    )
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :unavailable}
  end
end
