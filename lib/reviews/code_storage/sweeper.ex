defmodule Reviews.CodeStorage.Sweeper do
  @moduledoc """
  Periodic cleanup for code storage. Expires unclaimed snapshot reservations
  and deletes expired, never-claimed repositories (staging or failed) from the
  provider.

  Database status is the source of truth: every step is idempotent, and a
  crashed sweep is simply retried on the next tick. Disabled in the test env
  via `config :reviews, Reviews.CodeStorage.Sweeper, enabled: false` — tests
  call `sweep/1` directly.
  """
  use GenServer

  require Logger

  alias Reviews.{CodeSnapshots, CodeStorage, Repo}

  @default_interval_ms 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @doc "Run one sweep now. Public so tests can drive it synchronously."
  def sweep(now \\ DateTime.utc_now()) do
    expired = CodeSnapshots.expire_stale(now)

    if expired > 0 do
      Logger.info("code storage sweeper expired #{expired} unclaimed snapshot(s)")
    end

    delete_stale_repositories(now)
  end

  defp delete_stale_repositories(now) do
    adapter = CodeStorage.adapter()

    Repo.transaction(fn ->
      now
      |> CodeSnapshots.stale_staging_repositories()
      |> Enum.each(fn repository ->
        case adapter.delete_repository(repository) do
          :ok ->
            {:ok, _} = CodeSnapshots.delete_repository_row(repository)

          {:error, reason} ->
            # Leave the row for retry on the next sweep.
            {:ok, _} = CodeSnapshots.record_repository_error(repository, reason)

            Logger.warning(
              "code storage sweeper failed to delete repository: " <>
                CodeSnapshots.redact_error(reason)
            )
        end
      end)
    end)

    :ok
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, interval_ms())
  end

  defp interval_ms do
    Application.get_env(:reviews, __MODULE__, [])[:interval_ms] || @default_interval_ms
  end
end
