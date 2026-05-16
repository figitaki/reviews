defmodule Reviews.Release do
  @moduledoc """
  Release-time helpers — invoked from `rel/overlays/bin/migrate` so we can
  run Ecto migrations inside the release without a `mix` install.
  """

  @app :reviews

  @preview_github_id 0
  @preview_username "preview"
  @preview_token_name "preview-bootstrap"

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Seeds a synthetic "preview" user with an API token derived from the
  `PREVIEW_API_TOKEN` env var, so the CLI can `reviews login` against a
  preview app without going through GitHub OAuth (which doesn't work on
  per-PR hostnames). No-op if the env var is unset — production deploys
  set no `PREVIEW_API_TOKEN`, so this only takes effect on preview apps.

  Idempotent: re-running with the same token is a no-op; rotating the
  token inserts a new row alongside the old one.
  """
  def seed_preview_user do
    load_app()

    case System.get_env("PREVIEW_API_TOKEN") do
      nil ->
        :ok

      "" ->
        :ok

      raw ->
        for repo <- repos() do
          {:ok, _, _} = Ecto.Migrator.with_repo(repo, fn _ -> seed_preview_token(raw) end)
        end

        :ok
    end
  end

  @doc """
  Inserts (or no-ops) the synthetic preview user + token. Assumes the
  repo is already running — `seed_preview_user/0` is the release-time
  entrypoint that handles starting it via `Ecto.Migrator.with_repo/2`.
  Exposed for tests.
  """
  def seed_preview_token(raw) when is_binary(raw) do
    user =
      Reviews.Repo.get_by(Reviews.Accounts.User, github_id: @preview_github_id) ||
        Reviews.Repo.insert!(%Reviews.Accounts.User{
          github_id: @preview_github_id,
          username: @preview_username
        })

    hash = :crypto.hash(:sha256, raw)

    Reviews.Repo.insert!(
      %Reviews.Accounts.ApiToken{
        user_id: user.id,
        token_hash: hash,
        name: @preview_token_name
      },
      on_conflict: :nothing,
      conflict_target: :token_hash
    )

    :ok
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
