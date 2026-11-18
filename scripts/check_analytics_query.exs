#!/usr/bin/env elixir
# Run with elixir, not mix run. Requires local initdb, pg_ctl and psql.
defmodule AnalyticsQueryCheck do
  @moduledoc """
  Offline synthetic query-cost check with an isolated Unix-socket PostgreSQL
  cluster. No dependencies, application config, credentials or existing DB.
  Simplified tables model row width and primary/author indexes, not production
  data distribution or every index. This is not a production capacity test.
  """

  @tables [
    {"reviews", 100_000},
    {"patchsets", 200_000},
    {"comments", 300_000},
    {"packet_section_decisions", 100_000}
  ]

  def run! do
    # System.cmd merges env with the parent: nil explicitly REMOVES each PG key.
    # Apply this to every subprocess, including cluster startup and shutdown.
    env = for {key, _} <- System.get_env(), String.starts_with?(key, "PG"), do: {key, nil}
    tmp = command!("mktemp", ["-d", "/tmp/rv-analytics-perf-XXXXXXXX"], env) |> String.trim()
    db = Path.join(tmp, "db")

    try do
      command!(
        "initdb",
        ["-D", db, "-U", "analytics_check", "-A", "trust", "--no-locale", "--encoding=UTF8"],
        env
      )

      command!(
        "pg_ctl",
        [
          "-D",
          db,
          "-l",
          Path.join(tmp, "server.log"),
          "-o",
          "-k #{tmp} -h '' -p 5432",
          "-w",
          "start"
        ],
        env
      )

      # Explicit flags cannot be redirected by libpq defaults. Disable password
      # file loading too; this private cluster uses local trust auth only.
      client_env = [{"PGPASSFILE", "/dev/null"} | List.keydelete(env, "PGPASSFILE", 0)]

      args = [
        "-X",
        "-q",
        "-w",
        "-h",
        tmp,
        "-p",
        "5432",
        "-U",
        "analytics_check",
        "-d",
        "postgres",
        "-v",
        "ON_ERROR_STOP=1"
      ]

      setup = Path.join(tmp, "setup.sql")
      File.write!(setup, fixture_sql())
      command!("psql", args ++ ["-f", setup], client_env)
      query = File.read!(Path.expand("../priv/analytics/snapshot.sql", __DIR__))

      for run <- 1..2 do
        # Keep diagnostic warnings out of the JSON result.
        output = Path.join(tmp, "plan.json")

        command!(
          "psql",
          args ++
            [
              "-At",
              "-o",
              output,
              "-c",
              "SET work_mem='4MB'; SET statement_timeout='5s'; EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " <>
                query
            ],
          client_env
        )

        [plan] = output |> File.read!() |> JSON.decode!()

        %{
          run: run,
          execution_ms: plan["Execution Time"],
          planning_ms: plan["Planning Time"],
          shared_hit_blocks: plan["Plan"]["Shared Hit Blocks"],
          shared_read_blocks: plan["Plan"]["Shared Read Blocks"],
          temp_read_blocks: plan["Plan"]["Temp Read Blocks"],
          temp_written_blocks: plan["Plan"]["Temp Written Blocks"]
        }
        |> JSON.encode!()
        |> IO.puts()
      end
    after
      # Also handles partially successful startup. Never remove a live cluster's
      # files if shutdown fails; retain its directory for manual recovery.
      case File.exists?(Path.join(db, "postmaster.pid")) do
        true -> command!("pg_ctl", ["-D", db, "-m", "fast", "-w", "stop"], env)
        false -> :ok
      end

      File.rm_rf!(tmp)
    end
  end

  defp fixture_sql do
    tables =
      Enum.map_join(@tables, "\n", fn {table, count} ->
        """
        CREATE TABLE #{table}(id bigint PRIMARY KEY, inserted_at timestamp NOT NULL,
                             author_id bigint, payload text);
        CREATE INDEX ON #{table}(author_id);
        INSERT INTO #{table}
          SELECT n, date_trunc('second',transaction_timestamp()) AT TIME ZONE 'UTC'
                    - (n%90)*interval '1 day' - interval '1 second',
                 (n%60000)+1, repeat(md5(n::text),32)
          FROM generate_series(1,#{count}) n;
        """
      end)

    """
    BEGIN;
    CREATE TABLE identities(id bigint PRIMARY KEY, owner_user_id bigint NOT NULL);
    INSERT INTO identities SELECT n, (n+2)/3 FROM generate_series(1,60000) n;
    #{tables}
    ANALYZE;
    COMMIT;
    """
  end

  defp command!(program, args, env) do
    case System.cmd(program, args, env: env, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> raise "#{program} failed (#{status}):\n#{output}"
    end
  end
end

AnalyticsQueryCheck.run!()
