defmodule Reviews.OAuth.Registration do
  @moduledoc """
  Dynamic client registration (RFC 7591) for clients without a client ID
  metadata document, such as the MCP Inspector and Codex. Registered clients
  are public: no secret, PKCE on every authorization. Their `client_id`
  starts with `rvc_`, and the name they give is never shown as verified.

  Registration is on while a resource takes public clients
  (`Reviews.OAuth.public_clients?/0`).
  """
  import Ecto.Query, only: [from: 2]

  alias Reviews.OAuth.RegisteredClient
  alias Reviews.Repo

  @max_redirect_uris 10
  @max_uri_length 2_000

  @doc """
  Registers a public client. Only `redirect_uris` and `client_name` are kept;
  the client authenticates with PKCE alone (`token_endpoint_auth_method`
  `none`). Returns the registration response, or an RFC 7591 error code.
  """
  def register_client(params) when is_map(params) do
    redirect_uris = params["redirect_uris"]
    auth_method = Map.get(params, "token_endpoint_auth_method", "none")
    grant_types = Map.get(params, "grant_types", ["authorization_code"])
    response_types = Map.get(params, "response_types", ["code"])

    cond do
      not valid_redirect_uris?(redirect_uris) ->
        {:error, "invalid_redirect_uri"}

      auth_method != "none" ->
        {:error, "invalid_client_metadata",
         "Only public clients (token_endpoint_auth_method \"none\") can register."}

      not (is_list(grant_types) and "authorization_code" in grant_types and
               grant_types -- ["authorization_code", "refresh_token"] == []) ->
        {:error, "invalid_client_metadata", "Use the authorization_code grant."}

      response_types != ["code"] ->
        {:error, "invalid_client_metadata", "Use response_type \"code\"."}

      true ->
        client_id = "rvc_" <> (:crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false))

        client =
          Repo.insert!(%RegisteredClient{
            client_id: client_id,
            client_name: client_name(params["client_name"]),
            redirect_uris: redirect_uris
          })

        {:ok,
         %{
           "client_id" => client.client_id,
           "client_id_issued_at" => DateTime.to_unix(client.inserted_at),
           "client_name" => client.client_name,
           "redirect_uris" => client.redirect_uris,
           "token_endpoint_auth_method" => "none",
           "grant_types" => ["authorization_code", "refresh_token"],
           "response_types" => ["code"]
         }
         |> Map.reject(fn {_k, v} -> is_nil(v) end)}
    end
  end

  def register_client(_), do: {:error, "invalid_client_metadata", "Send a JSON object."}

  @doc "The registered client named `client_id`, as `Reviews.OAuth.Clients` describes clients."
  def registered_client("rvc_" <> _ = client_id) do
    case Repo.one(from c in RegisteredClient, where: c.client_id == ^client_id) do
      %RegisteredClient{} = client ->
        {:ok,
         %{
           client_id: client.client_id,
           client_name: client.client_name,
           redirect_uris: client.redirect_uris,
           auth_methods: ["none"],
           registered: true,
           jwks_uri: nil,
           keys: []
         }}

      nil ->
        {:error, :unknown_client}
    end
  end

  def registered_client(_), do: {:error, :unknown_client}

  defp client_name(name) when is_binary(name) and name != "", do: String.slice(name, 0, 120)
  defp client_name(_), do: nil

  defp valid_redirect_uris?(uris) when is_list(uris) and uris != [] do
    length(uris) <= @max_redirect_uris and Enum.all?(uris, &valid_redirect_uri?/1)
  end

  defp valid_redirect_uris?(_), do: false

  # HTTPS, an HTTP loopback address (RFC 8252 §7.3), or an app's private-use
  # scheme (RFC 8252 §7.1). Never a fragment, credentials, or a scheme a
  # browser runs.
  @doc false
  def valid_redirect_uri?(uri) when is_binary(uri) and byte_size(uri) <= @max_uri_length do
    case URI.new(uri) do
      {:ok, %URI{fragment: nil, userinfo: nil, scheme: scheme} = parsed} when is_binary(scheme) ->
        case String.downcase(scheme) do
          "https" -> is_binary(parsed.host) and parsed.host != ""
          "http" -> Reviews.OAuth.Clients.loopback_redirect?(uri)
          scheme when scheme in ~w(javascript data file vbscript about blob ws wss ftp) -> false
          scheme -> scheme =~ ~r/\A[a-z][a-z0-9+.-]*\z/
        end

      _ ->
        false
    end
  end

  def valid_redirect_uri?(_), do: false
end
