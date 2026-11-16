defmodule Reviews.OAuth.Clients do
  @moduledoc """
  OAuth clients of the Reviews issuer.

  A URL `client_id` names a client ID metadata document, as connectors such
  as Claude and ChatGPT publish. This module fetches, checks, and caches it and the key set at its
  `jwks_uri`, if it has one. A client with keys authenticates at the token
  endpoint with `private_key_jwt`; one without is a public client (`none`)
  that relies on PKCE. An `rvc_` ID names a client registered through dynamic
  client registration (`Reviews.OAuth.Registration`).

  The cache lives in ETS on each node. Entries last `:client_cache_seconds`
  (default 300), so a key removed from `jwks_uri` stops being trusted within
  that time. An unknown `kid` refetches the key set at most once every 30
  seconds per client, and failed fetches are remembered for 30 seconds too, so
  forged requests can't make Reviews flood a client's server.
  """
  use GenServer

  alias Reviews.OAuth
  alias Reviews.OAuth.{Fetcher, JOSE}

  @table __MODULE__
  @refetch_interval 30

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  # Token endpoint authentication methods the issuer accepts.
  @auth_methods ["none", "private_key_jwt"]

  @type client :: %{
          client_id: String.t(),
          client_name: String.t() | nil,
          jwks_uri: String.t() | nil,
          redirect_uris: [String.t()],
          auth_methods: [String.t()],
          registered: boolean(),
          keys: [map()]
        }

  @doc "The verified metadata for `client_id`, or why it can't be used."
  @spec fetch(String.t()) :: {:ok, client()} | {:error, atom()}
  def fetch(client_id) when is_binary(client_id) do
    now = now()

    cond do
      client_id in OAuth.config(:blocked_clients, []) ->
        {:error, :client_refused}

      String.starts_with?(client_id, "rvc_") ->
        Reviews.OAuth.Registration.registered_client(client_id)

      not valid_client_id?(client_id) ->
        {:error, :invalid_client_id}

      true ->
        case :ets.lookup(@table, client_id) do
          [{_, {:ok, client}, expires_at, _jwks_at}] when expires_at > now -> {:ok, client}
          [{_, {:error, _} = error, expires_at, _}] when expires_at > now -> error
          _ -> load(client_id, now)
        end
    end
  end

  def fetch(_), do: {:error, :invalid_client_id}

  @doc "Drops the cached metadata and keys for `client_id`, such as after a key leak."
  def forget(client_id), do: :ets.delete(@table, client_id)

  @doc """
  The key named `kid` in the client's key set. Refetches the key set once per
  interval when the `kid` is unknown.
  """
  @spec key(client(), term()) :: {:ok, map()} | {:error, :unknown_key}
  def key(%{jwks_uri: nil}, _kid), do: {:error, :unknown_key}

  def key(%{keys: keys} = client, kid) when is_binary(kid) do
    case Enum.find(keys, &(&1["kid"] == kid)) do
      nil -> refetch_key(client, kid)
      key -> {:ok, key}
    end
  end

  def key(_client, _kid), do: {:error, :unknown_key}

  defp refetch_key(%{client_id: client_id}, kid) do
    now = now()

    case :ets.lookup(@table, client_id) do
      [{_, {:ok, cached}, expires_at, jwks_at}] when now - jwks_at >= @refetch_interval ->
        client =
          case fetch_keys(cached.jwks_uri) do
            {:ok, keys} -> %{cached | keys: keys}
            {:error, _} -> cached
          end

        :ets.insert(@table, {client_id, {:ok, client}, expires_at, now})

        case Enum.find(client.keys, &(&1["kid"] == kid)) do
          nil -> {:error, :unknown_key}
          key -> {:ok, key}
        end

      _ ->
        {:error, :unknown_key}
    end
  end

  defp load(client_id, now) do
    result =
      with {:ok, metadata} <- fetch_json(client_id),
           {:ok, client} <- check_metadata(client_id, metadata),
           {:ok, keys} <- maybe_fetch_keys(client.jwks_uri) do
        {:ok, Map.put(client, :keys, keys)}
      end

    ttl =
      case result do
        {:ok, _} -> OAuth.config(:client_cache_seconds, 300)
        {:error, _} -> @refetch_interval
      end

    :ets.insert(@table, {client_id, result, now + ttl, now})
    result
  end

  defp fetch_json(url) do
    case Fetcher.get(url) do
      {:ok, %{status: 200, body: body}} ->
        case JSON.decode(body) do
          {:ok, %{} = json} -> {:ok, json}
          _ -> {:error, :invalid_client_metadata}
        end

      {:ok, %{status: _}} ->
        {:error, :client_metadata_unavailable}

      {:error, _} ->
        {:error, :client_metadata_unavailable}
    end
  end

  defp check_metadata(client_id, %{"client_id" => client_id} = metadata) do
    host = URI.parse(client_id).host
    jwks_uri = metadata["jwks_uri"]
    redirect_uris = Map.get(metadata, "redirect_uris", [])
    name = metadata["client_name"]
    auth_methods = auth_methods(metadata, is_binary(jwks_uri))

    cond do
      not (is_nil(jwks_uri) or https_on_host?(jwks_uri, host)) ->
        {:error, :invalid_client_metadata}

      not is_list(redirect_uris) or redirect_uris == [] or
          not Enum.all?(redirect_uris, &(https_on_host?(&1, host) or loopback_redirect?(&1))) ->
        {:error, :invalid_client_metadata}

      auth_methods == [] ->
        {:error, :invalid_client_metadata}

      true ->
        {:ok,
         %{
           client_id: client_id,
           client_name: if(is_binary(name), do: String.slice(name, 0, 120)),
           jwks_uri: jwks_uri,
           redirect_uris: redirect_uris,
           auth_methods: auth_methods,
           registered: false
         }}
    end
  end

  defp check_metadata(_client_id, _metadata), do: {:error, :invalid_client_metadata}

  # The methods both sides support. The plural field lists every method the
  # client can use (MCP SEP-3149); without it the singular one is binding,
  # and without either a client with keys uses them. `private_key_jwt` needs
  # a key set.
  defp auth_methods(metadata, has_keys?) do
    declared =
      case metadata do
        %{"token_endpoint_auth_methods_supported" => methods} when is_list(methods) -> methods
        %{"token_endpoint_auth_method" => method} when is_binary(method) -> [method]
        _ when has_keys? -> ["private_key_jwt"]
        _ -> ["none"]
      end

    Enum.filter(@auth_methods, &(&1 in declared and (&1 == "none" or has_keys?)))
  end

  defp maybe_fetch_keys(nil), do: {:ok, []}
  defp maybe_fetch_keys(jwks_uri), do: fetch_keys(jwks_uri)

  defp fetch_keys(jwks_uri) do
    case fetch_json(jwks_uri) do
      {:ok, %{"keys" => keys}} when is_list(keys) ->
        {:ok, Enum.filter(keys, &(is_map(&1) and JOSE.public_key?(&1)))}

      _ ->
        {:error, :invalid_jwks}
    end
  end

  @doc "A client_id is an HTTPS URL with a path and no fragment, query, or credentials."
  def valid_client_id?(client_id) do
    case URI.parse(client_id) do
      %URI{scheme: "https", host: host, path: path, fragment: nil, query: nil, userinfo: nil}
      when is_binary(host) and host != "" and is_binary(path) and path != "/" ->
        not String.contains?(path, ["/./", "/../"])

      _ ->
        false
    end
  end

  defp https_on_host?(url, host) when is_binary(url) do
    match?(%URI{scheme: "https", host: ^host, fragment: nil, userinfo: nil}, URI.parse(url))
  end

  defp https_on_host?(_url, _host), do: false

  @doc """
  A loopback redirect URI (RFC 8252 §7.3): http and a loopback IP literal, or
  `localhost`, which Claude Code and other MCP clients register.
  """
  def loopback_redirect?(url) when is_binary(url) do
    match?(
      %URI{scheme: "http", host: host, fragment: nil, userinfo: nil}
      when host in ["127.0.0.1", "::1", "localhost"],
      URI.parse(url)
    )
  end

  def loopback_redirect?(_url), do: false

  defp now, do: System.system_time(:second)
end
