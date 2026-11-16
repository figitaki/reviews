defmodule Reviews.ReleasePreviewDbTest do
  # Not async: these tests create and drop a real database on the local
  # Postgres server, outside the SQL sandbox.
  use ExUnit.Case, async: false

  alias Reviews.Release

  # A PR number no real preview uses, plus the OS pid so parallel runs on
  # one machine do not collide.
  @db_name "reviews_pr_9#{System.pid()}"

  defp config_for(name) do
    Reviews.Repo.config()
    |> Keyword.drop([:pool])
    |> Keyword.put(:database, name)
  end

  defp database_exists?(name) do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        Reviews.Repo,
        "SELECT 1 FROM pg_database WHERE datname = $1",
        [name]
      )

    rows != []
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Reviews.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Reviews.Repo, {:shared, self()})
    on_exit(fn -> Reviews.Repo.__adapter__().storage_down(config_for(@db_name)) end)
    :ok
  end

  describe "preview_db_name?/1" do
    test "accepts reviews_pr_ followed by digits" do
      assert Release.preview_db_name?("reviews_pr_1")
      assert Release.preview_db_name?("reviews_pr_8312")
    end

    test "rejects anything else" do
      refute Release.preview_db_name?("reviews_pr_")
      refute Release.preview_db_name?("reviews_pr_12a")
      refute Release.preview_db_name?("reviews_pr_12\n")
      refute Release.preview_db_name?("reviews_pr_1; DROP DATABASE x")
      refute Release.preview_db_name?(~s(reviews_pr_1" WITH OWNER x))
      refute Release.preview_db_name?("reviews_preview")
      refute Release.preview_db_name?("reviews")
      refute Release.preview_db_name?("postgres")
      refute Release.preview_db_name?("REVIEWS_PR_1")
      refute Release.preview_db_name?(nil)
    end
  end

  describe "ensure_database/2" do
    test "creates the database and is idempotent" do
      config = config_for(@db_name)
      refute database_exists?(@db_name)

      assert :ok = Release.ensure_database(@db_name, config)
      assert database_exists?(@db_name)
      assert :ok = Release.ensure_database(@db_name, config)
    end

    test "refuses a name that is not reviews_pr_<digits>" do
      # Never hand a real database name to destructive code, even when
      # testing the guard that is supposed to reject it.
      for name <- ["not_a_preview_#{System.pid()}", "reviews_pr_1x", "reviews_pr_1\n"] do
        assert_raise ArgumentError, ~r/must match reviews_pr_<digits>/, fn ->
          Release.ensure_database(name, config_for(name))
        end
      end
    end

    test "refuses when DATABASE_URL names a different database" do
      shared = config_for("reviews_preview")

      assert_raise ArgumentError, ~r/DATABASE_URL names "reviews_preview"/, fn ->
        Release.ensure_database(@db_name, shared)
      end

      refute database_exists?(@db_name)
    end
  end

  describe "env entrypoints" do
    test "are no-ops without PREVIEW_DB_NAME" do
      System.delete_env("PREVIEW_DB_NAME")
      assert :ok = Release.ensure_database()
    end

    test "refuse a PREVIEW_DB_NAME that DATABASE_URL does not name" do
      System.put_env("PREVIEW_DB_NAME", @db_name)
      on_exit(fn -> System.delete_env("PREVIEW_DB_NAME") end)

      assert_raise ArgumentError, ~r/DATABASE_URL names/, fn -> Release.ensure_database() end

      refute database_exists?(@db_name)
    end

    test "refuse a PREVIEW_DB_NAME that is not reviews_pr_<digits>" do
      System.put_env("PREVIEW_DB_NAME", "reviews")
      on_exit(fn -> System.delete_env("PREVIEW_DB_NAME") end)

      assert_raise ArgumentError, ~r/must match/, fn -> Release.ensure_database() end
    end
  end
end
