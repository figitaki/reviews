defmodule Reviews.ConfigFileTest do
  # Reads and sets process environment variables.
  use ExUnit.Case, async: false

  alias Reviews.ConfigFile

  @secrets ~w(SECRET_KEY_BASE DATABASE_URL GITHUB_CLIENT_SECRET)

  setup do
    saved = Map.new(@secrets, &{&1, System.get_env(&1)})
    Enum.each(@secrets, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    dir = Path.join(System.tmp_dir!(), "config_file_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp load(dir, yaml) do
    path = Path.join(dir, "reviews.yaml")
    File.write!(path, yaml)
    ConfigFile.load!(path)
  end

  defp errors(dir, yaml) do
    error = assert_raise RuntimeError, fn -> load(dir, yaml) end
    error.message
  end

  test "no file means nothing from the file" do
    assert ConfigFile.load!(nil) == %{env: %{}, rate_limits: [], body_limits: []}
    assert ConfigFile.load!("") == %{env: %{}, rate_limits: [], body_limits: []}
  end

  test "the example file loads, with its secrets from the environment" do
    System.put_env("SECRET_KEY_BASE", "from-env")
    System.put_env("DATABASE_URL", "ecto://u:p@db/reviews")
    System.put_env("GITHUB_CLIENT_SECRET", "from-env")

    config = ConfigFile.load!("config/reviews.example.yaml")

    assert config.env["PHX_HOST"] == "reviews.example.com"
    assert config.env["PORT"] == "4000"
    assert config.env["POOL_SIZE"] == "10"
    assert config.env["ECTO_IPV6"] == "false"
    assert config.env["CODE_STORAGE_POLICY"] == "optional"
    assert config.env["WEBSOCKET_EXTRA_ORIGINS"] == ""
    # Set in the environment, so the files are not read.
    refute Map.has_key?(config.env, "SECRET_KEY_BASE")
    refute Map.has_key?(config.env, "DATABASE_URL")
    # Disabled code storage and null keys set nothing.
    refute Map.has_key?(config.env, "CODE_STORAGE_ADAPTER")
    refute Map.has_key?(config.env, "LEGAL_PRIVACY_URL")
    assert config.rate_limits[:writes] == 60

    assert Enum.sort(config.body_limits) == [
             mcp_bytes: 4_000_000,
             small_bytes: 64_000,
             upload_bytes: 50_000_000
           ]
  end

  test "maps keys to environment values", %{dir: dir} do
    File.write!(Path.join(dir, "skb"), "secret-from-file\n")

    config =
      load(dir, """
      server:
        host: reviews.example.org
        secret_key_base_file: #{dir}/skb
        websocket_extra_origins: [https://a.example.com, http://b.example.com:8080]
      database: {pool_size: 5e+07, ipv6: true}
      code_storage: {enabled: true}
      legal: {updated: 2026-11-21}
      """)

    assert config.env == %{
             "PHX_HOST" => "reviews.example.org",
             "SECRET_KEY_BASE" => "secret-from-file",
             "WEBSOCKET_EXTRA_ORIGINS" => "https://a.example.com,http://b.example.com:8080",
             "POOL_SIZE" => "50000000",
             "ECTO_IPV6" => "true",
             "CODE_STORAGE_ADAPTER" => "code_storage",
             "LEGAL_UPDATED" => "2026-11-21"
           }
  end

  test "names every bad key at once", %{dir: dir} do
    message =
      errors(dir, """
      server:
        host: 42
        port: 70000
        hots: x
      database:
        pool_size: 0
      mcp:
        enabled: "yes"
      code_storage:
        policy: always
      limits:
        rate: {writes: 1.5}
      extra: 1
      """)

    for line <- [
          "database.pool_size: must be a whole number above 0, got 0",
          "extra: unknown key. Known keys: analytics, auth_relay,",
          "limits.rate.writes: must be a whole number above 0, got 1.5",
          "mcp.enabled: must be true or false, got \"yes\"",
          "code_storage.policy: must be one of optional, required, got \"always\"",
          "server.host: must be a string, got 42",
          "server.hots: unknown key. Known keys in server: design_catalog, host,",
          "server.port: must be a port number from 1 to 65535, got 70000"
        ] do
      assert message =~ line
    end
  end

  test "refuses inline secrets and points at the _file key", %{dir: dir} do
    message = errors(dir, "github:\n  client_secret: hunter2\n")

    assert message =~
             "github.client_secret: secrets cannot be written in the file. " <>
               "Set github.client_secret_file to the path of a file that holds it, " <>
               "or set GITHUB_CLIENT_SECRET"

    refute message =~ "hunter2"
  end

  test "a missing or empty secret file is an error naming the key", %{dir: dir} do
    File.write!(Path.join(dir, "empty"), "\n")

    message =
      errors(dir, """
      server: {secret_key_base_file: #{dir}/empty}
      database: {url_file: #{dir}/missing}
      """)

    assert message =~ "server.secret_key_base_file: #{dir}/empty is empty"
    assert message =~ "database.url_file: cannot read #{dir}/missing: no such file or directory"
  end

  test "rejects a file that is not a mapping, and invalid YAML", %{dir: dir} do
    assert errors(dir, "- a\n- b\n") =~ "(top level): must be a mapping"
    assert errors(dir, "server: [1\n") =~ "is not valid YAML"

    assert_raise RuntimeError, ~r/cannot be read: no such file or directory/, fn ->
      ConfigFile.load!(Path.join(dir, "nope.yaml"))
    end
  end
end
