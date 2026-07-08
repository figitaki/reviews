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

    hash = :crypto.hash(:sha256, raw)

    if column_exists?("api_tokens", "identity_id") do
      identity_id = seed_preview_identity(user)

      Ecto.Adapters.SQL.query!(
        Reviews.Repo,
        """
        INSERT INTO api_tokens (user_id, identity_id, token_hash, name, inserted_at)
        VALUES ($1, $2, $3, $4, NOW())
        ON CONFLICT (token_hash) DO NOTHING
        """,
        [user.id, identity_id, hash, @preview_token_name]
      )
    else
      Reviews.Repo.insert!(
        %Reviews.Accounts.ApiToken{
          user_id: user.id,
          token_hash: hash,
          name: @preview_token_name
        },
        on_conflict: :nothing,
        conflict_target: :token_hash
      )
    end

    :ok
  end

  defp seed_preview_identity(user) do
    %{rows: [[identity_id]]} =
      Ecto.Adapters.SQL.query!(
        Reviews.Repo,
        """
        INSERT INTO identities (
          owner_user_id,
          kind,
          handle,
          display_name,
          avatar_url,
          provider,
          inserted_at,
          updated_at
        )
        VALUES ($1, 'human', $2, $2, $3, 'GitHub', NOW(), NOW())
        ON CONFLICT (owner_user_id) WHERE kind = 'human'
        DO UPDATE SET
          handle = EXCLUDED.handle,
          display_name = EXCLUDED.display_name,
          avatar_url = EXCLUDED.avatar_url,
          provider = EXCLUDED.provider,
          updated_at = EXCLUDED.updated_at
        RETURNING id
        """,
        [user.id, user.username, user.avatar_url]
      )

    identity_id
  end

  defp column_exists?(table, column) do
    %{rows: [[count]]} =
      Ecto.Adapters.SQL.query!(
        Reviews.Repo,
        """
        SELECT count(*)
        FROM information_schema.columns
        WHERE table_schema = current_schema()
          AND table_name = $1
          AND column_name = $2
        """,
        [table, column]
      )

    count > 0
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
