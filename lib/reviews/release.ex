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

  @doc """
  Creates the per-PR preview database if it does not exist yet.

  Runs first in `rel/overlays/bin/migrate`. It is a no-op unless
  `PREVIEW_DB_NAME` is set, and production sets no `PREVIEW_DB_NAME`.

  The preview workflow sets `PREVIEW_DB_NAME=reviews_pr_<N>` and points
  `DATABASE_URL` at that database. `CREATE DATABASE` runs through the
  Postgres maintenance database (`postgres`) on the same server, with the
  same credentials. If `DATABASE_URL` does not name the same database as
  `PREVIEW_DB_NAME`, this raises, so a preview app never migrates a
  database that it does not own.
  """
  def ensure_database do
    load_app()

    with {:ok, name} <- preview_db_name_from_env() do
      ensure_database(name, Reviews.Repo.config())
    end
  end

  @doc """
  Creates the preview database `name` with the connection settings in
  `repo_config`. Returns `:ok` when the database exists after the call.
  Exposed for tests.
  """
  def ensure_database(name, repo_config) do
    name = check_preview_target!(name, repo_config)

    case Reviews.Repo.__adapter__().storage_up(repo_config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> raise "could not create preview database #{name}: #{inspect(reason)}"
    end
  end

  @doc """
  Drops the per-PR preview database. The preview workflow calls this
  when the PR closes, before it destroys the Fly app.

  It is a no-op unless `PREVIEW_DB_NAME` is set. It drops only a database
  whose name matches `reviews_pr_<digits>` and that `DATABASE_URL` also
  names. It uses `DROP DATABASE ... WITH (FORCE)`, because the running
  app holds open connections to the database.
  """
  def drop_preview_database do
    load_app()

    with {:ok, name} <- preview_db_name_from_env() do
      drop_preview_database(name, Reviews.Repo.config())
    end
  end

  @doc """
  Drops the preview database `name` with the connection settings in
  `repo_config`. Returns `:ok` when the database is gone after the call.
  Exposed for tests.
  """
  def drop_preview_database(name, repo_config) do
    name = check_preview_target!(name, repo_config)

    case Reviews.Repo.__adapter__().storage_down(Keyword.put(repo_config, :force_drop, true)) do
      :ok -> :ok
      {:error, :already_down} -> :ok
      {:error, reason} -> raise "could not drop preview database #{name}: #{inspect(reason)}"
    end
  end

  @doc """
  Returns `true` when `name` is a valid preview database name:
  `reviews_pr_` followed by digits only.
  """
  def preview_db_name?(name) when is_binary(name),
    do: Regex.match?(~r/\Areviews_pr_[0-9]+\z/, name)

  def preview_db_name?(_), do: false

  defp preview_db_name_from_env do
    case System.get_env("PREVIEW_DB_NAME") do
      nil -> :ok
      "" -> :ok
      name -> {:ok, name}
    end
  end

  defp check_preview_target!(name, repo_config) do
    unless preview_db_name?(name) do
      raise ArgumentError,
            "refusing to use preview database #{inspect(name)}: " <>
              "the name must match reviews_pr_<digits>"
    end

    unless repo_config[:database] == name do
      raise ArgumentError,
            "refusing to use preview database #{inspect(name)}: " <>
              "DATABASE_URL names #{inspect(repo_config[:database])}, not #{inspect(name)}"
    end

    name
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
  Seeds the bundled demo review used by the homepage and hosted demos.
  """
  def seed_demo_review do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _ ->
          Reviews.DemoReview.seed!()
          :ok
        end)
    end

    :ok
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

    {:ok, identity} = Reviews.Accounts.ensure_human_identity(user)

    hash = :crypto.hash(:sha256, raw)

    Reviews.Repo.insert!(
      %Reviews.Accounts.ApiToken{
        user_id: user.id,
        identity_id: identity.id,
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
