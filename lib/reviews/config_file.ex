defmodule Reviews.ConfigFile do
  @moduledoc """
  Reads the deployment config file named by `REVIEWS_CONFIG`
  (docs/CONFIGURATION.md, example in `config/reviews.example.yaml`).

  `config/runtime.exs` calls `load!/1` at boot. Most keys stand for one
  environment variable, and a set environment variable wins over the file, so
  a deployment configured only through the environment works as before. The
  `limits` keys have no environment variable.

  Secrets are never written in the file. Each secret key ends in `_file` and
  names a file holding the value, such as a mounted Kubernetes Secret. The
  file is read only when its environment variable is unset.

  Every problem is reported at once, by key path, and unknown keys are errors.
  """

  # Leaf: {type, target}. The target is an environment variable name, or
  # {:rate, key} / {:body, key} for the request budgets.
  @schema %{
    "server" => %{
      "host" => {:string, "PHX_HOST"},
      "port" => {:port, "PORT"},
      "secret_key_base_file" => {:secret_file, "SECRET_KEY_BASE"},
      "websocket_extra_origins" => {:origins, "WEBSOCKET_EXTRA_ORIGINS"},
      "design_catalog" => {:boolean, "DESIGN_CATALOG"}
    },
    "database" => %{
      "url_file" => {:secret_file, "DATABASE_URL"},
      "pool_size" => {:positive_integer, "POOL_SIZE"},
      "ipv6" => {:boolean, "ECTO_IPV6"}
    },
    "cluster" => %{
      "dns_query" => {:string, "DNS_CLUSTER_QUERY"}
    },
    "github" => %{
      "client_id" => {:string, "GITHUB_CLIENT_ID"},
      "client_secret_file" => {:secret_file, "GITHUB_CLIENT_SECRET"}
    },
    "mcp" => %{
      "enabled" => {:boolean, "MCP_ENABLED"},
      "writes_enabled" => {:boolean, "MCP_WRITES_ENABLED"}
    },
    "code_storage" => %{
      "enabled" => {{:flag, "code_storage"}, "CODE_STORAGE_ADAPTER"},
      "org" => {:string, "CODE_STORAGE_ORG"},
      "jwt_private_key_file" => {:secret_file, "CODE_STORAGE_JWT_PRIVATE_KEY"},
      "policy" => {{:enum, ~w(optional required)}, "CODE_STORAGE_POLICY"}
    },
    "legal" => %{
      "privacy_url" => {:string, "LEGAL_PRIVACY_URL"},
      "terms_url" => {:string, "LEGAL_TERMS_URL"},
      "operator_name" => {:string, "LEGAL_OPERATOR_NAME"},
      "contact_email" => {:string, "LEGAL_CONTACT_EMAIL"},
      "updated" => {:string, "LEGAL_UPDATED"},
      "hosting_region" => {:string, "LEGAL_HOSTING_REGION"},
      "log_retention" => {:string, "LEGAL_LOG_RETENTION"},
      "backup_retention" => {:string, "LEGAL_BACKUP_RETENTION"},
      "governing_law" => {:string, "LEGAL_GOVERNING_LAW"},
      "venue" => {:string, "LEGAL_VENUE"},
      "liability_cap" => {:string, "LEGAL_LIABILITY_CAP"}
    },
    "analytics" => %{
      "token_sha256_file" => {:secret_file, "REVIEWS_ANALYTICS_TOKEN_SHA256"},
      "token_expires_at" => {:string, "REVIEWS_ANALYTICS_TOKEN_EXPIRES_AT"}
    },
    "auth_relay" => %{
      "secret_file" => {:secret_file, "AUTH_RELAY_SECRET"},
      "url" => {:string, "AUTH_RELAY_URL"},
      "preview_host" => {:string, "AUTH_RELAY_PREVIEW_HOST"}
    },
    "limits" => %{
      "rate" => %{
        "requests" => {:positive_integer, {:rate, :requests}},
        "writes" => {:positive_integer, {:rate, :writes}},
        "uploads" => {:positive_integer, {:rate, :uploads}},
        "sockets" => {:positive_integer, {:rate, :sockets}},
        "owners" => {:positive_integer, {:rate, :owners}}
      },
      "body_bytes" => %{
        "upload" => {:positive_integer, {:body, :upload_bytes}},
        "mcp" => {:positive_integer, {:body, :mcp_bytes}},
        "other" => {:positive_integer, {:body, :small_bytes}}
      }
    }
  }

  @empty %{env: %{}, rate_limits: [], body_limits: []}

  @doc """
  Reads and checks the file at `path`. Returns `env`, a map of environment
  variable names to the string values the file gives them, and
  `rate_limits` / `body_limits` keyword lists. `nil` or `""` means no file.
  Raises naming every bad key.
  """
  def load!(path) when path in [nil, ""], do: @empty

  def load!(path) do
    {result, errors} = path |> read_yaml!() |> walk(@schema, [], {@empty, []})

    if errors != [] do
      raise """
      the config file #{path} (REVIEWS_CONFIG) is not valid:
      #{errors |> Enum.reverse() |> Enum.map_join("\n", &("  - " <> &1))}
      """
    end

    result
  end

  # yaml_elixir starts yamerl. Stop it again when it was not running, so the
  # release's boot script starts it as usual.
  defp read_yaml!(path) do
    running? = List.keymember?(Application.started_applications(), :yamerl, 0)

    try do
      case YamlElixir.read_from_file(path) do
        {:ok, data} ->
          data

        {:error, %YamlElixir.FileNotFoundError{} = error} ->
          raise "REVIEWS_CONFIG: #{Exception.message(error)}"

        {:error, error} ->
          raise "the config file #{path} (REVIEWS_CONFIG) is not valid YAML: " <>
                  "#{Exception.message(error)} (line #{error.line}, column #{error.column})"
      end
    after
      unless running?, do: Application.stop(:yamerl)
    end
  end

  defp walk(nil, _schema, _path, acc), do: acc

  defp walk(data, schema, path, acc) when is_map(data) do
    data
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.reduce(acc, fn {key, value}, acc -> walk_key(key, value, schema, path, acc) end)
  end

  defp walk(_data, _schema, path, acc),
    do: error(acc, path, "must be a mapping of keys to values")

  defp walk_key(key, value, schema, path, acc) do
    key_path = path ++ [to_string(key)]

    case is_binary(key) && Map.get(schema, key) do
      sub when is_map(sub) ->
        walk(value, sub, key_path, acc)

      {_type, _target} when is_nil(value) ->
        acc

      {type, target} ->
        case cast(type, value, target) do
          :skip -> acc
          {:ok, value} -> put(acc, target, value)
          {:error, message} -> error(acc, key_path, message)
        end

      _ ->
        error(acc, key_path, unknown_key(key, schema, path))
    end
  end

  defp unknown_key(key, schema, path) do
    secret = "#{key}_file"

    case schema do
      %{^secret => {:secret_file, env}} ->
        "secrets cannot be written in the file. Set #{dotted(path ++ [secret])} " <>
          "to the path of a file that holds it, or set #{env}"

      _ ->
        "unknown key. Known keys#{if path != [], do: " in #{dotted(path)}"}: " <>
          (schema |> Map.keys() |> Enum.sort() |> Enum.join(", "))
    end
  end

  defp cast(:string, value, _) when is_binary(value), do: {:ok, value}
  defp cast(:string, value, _), do: {:error, "must be a string, got #{inspect(value)}"}

  defp cast(:boolean, value, _) when is_boolean(value), do: {:ok, to_string(value)}
  defp cast(:boolean, value, _), do: {:error, "must be true or false, got #{inspect(value)}"}

  defp cast({:flag, on}, true, _), do: {:ok, on}
  defp cast({:flag, _}, false, _), do: :skip
  defp cast({:flag, _}, value, _), do: {:error, "must be true or false, got #{inspect(value)}"}

  defp cast({:enum, allowed}, value, _) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, "must be one of #{Enum.join(allowed, ", ")}, got #{inspect(value)}"}
  end

  defp cast(:port, value, target) do
    case integer(value) do
      {:ok, int} when int in 1..65_535 -> {:ok, int}
      _ -> {:error, "must be a port number from 1 to 65535, got #{inspect(value)}"}
    end
    |> stringify(target)
  end

  defp cast(:positive_integer, value, target) do
    case integer(value) do
      {:ok, int} when int > 0 -> {:ok, int}
      _ -> {:error, "must be a whole number above 0, got #{inspect(value)}"}
    end
    |> stringify(target)
  end

  defp cast(:origins, value, _) when is_list(value) do
    if Enum.all?(value, &(is_binary(&1) and String.match?(&1, ~r{\Ahttps?://[^/,\s]+\z}))),
      do: {:ok, Enum.join(value, ",")},
      else: {:error, "must be a list of origins such as https://old.example.com, with no path"}
  end

  defp cast(:origins, value, _),
    do:
      {:error,
       "must be a list of origins such as [https://old.example.com], got #{inspect(value)}"}

  defp cast(:secret_file, value, env) when is_binary(value) do
    if System.get_env(env) do
      :skip
    else
      case File.read(value) do
        {:ok, contents} ->
          case String.trim_trailing(contents) do
            "" -> {:error, "#{value} is empty"}
            secret -> {:ok, secret}
          end

        {:error, reason} ->
          {:error, "cannot read #{value}: #{:file.format_error(reason)}"}
      end
    end
  end

  defp cast(:secret_file, value, _), do: {:error, "must be a file path, got #{inspect(value)}"}

  # Helm's toYaml writes large whole numbers as floats, such as 5e+07.
  defp integer(value) when is_integer(value), do: {:ok, value}
  defp integer(value) when is_float(value) and value == trunc(value), do: {:ok, trunc(value)}
  defp integer(_), do: :error

  defp stringify({:ok, int}, name) when is_binary(name), do: {:ok, Integer.to_string(int)}
  defp stringify(result, _), do: result

  defp put({result, errors}, {:rate, key}, value),
    do: {%{result | rate_limits: Keyword.put(result.rate_limits, key, value)}, errors}

  defp put({result, errors}, {:body, key}, value),
    do: {%{result | body_limits: Keyword.put(result.body_limits, key, value)}, errors}

  defp put({result, errors}, name, value),
    do: {%{result | env: Map.put(result.env, name, value)}, errors}

  defp error({result, errors}, path, message),
    do: {result, ["#{if path == [], do: "(top level)", else: dotted(path)}: #{message}" | errors]}

  defp dotted(path), do: Enum.join(path, ".")
end
