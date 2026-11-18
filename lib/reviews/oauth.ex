defmodule Reviews.OAuth do
  @moduledoc """
  The Reviews OAuth 2.1 issuer, built on [gatekeep](https://github.com/figitaki/gatekeep).

  Gatekeep runs the protocol: authorization requests, PKCE, client ID
  metadata documents, dynamic client registration, `private_key_jwt`, the
  token endpoint with refresh rotation, revocation, DPoP, and the metadata
  documents. Reviews' controllers call it (`ReviewsWeb.OAuthController`,
  `ReviewsWeb.OAuthDiscoveryController`), and Reviews decides who may
  approve what:

    * An app never gets account access by itself. The owner signs in to
      Reviews with GitHub, picks one of their agent identities, and approves
      scopes for one resource (`approve/4`). The approval is a gatekeep grant
      whose subject is that agent identity and whose owner is the person, so
      every token issued under it acts as the agent, never as the person.
    * The APIs that accept these tokens are `Reviews.OAuth.Resource`
      modules, listed in `config :reviews, Reviews.OAuth, resources: [...]`.
      A token issued for one resource is refused by every other.

  `config/0` builds the gatekeep config from `config :reviews, Reviews.OAuth`
  on every call, because the issuer defaults to the endpoint's public URL and
  the resources derive their identifiers from it. Besides `:resources` and
  `:default_resource` (modules here), the keys are `Gatekeep.Config` options.
  """

  alias Gatekeep.{Authorization, Config, Metadata, Resource, Token}
  alias Reviews.Accounts
  alias Reviews.Accounts.{Identity, User}
  alias Reviews.OAuth.{Grant, Issuer}
  alias Reviews.Repo

  @doc """
  The gatekeep config of the issuer. Pass it to `Gatekeep` functions;
  `ReviewsWeb.OAuthController` passes `Reviews.OAuth` as the `:gatekeep`
  module.
  """
  @spec config() :: Config.t()
  def config do
    env = Application.get_env(:reviews, __MODULE__, [])
    {modules, env} = Keyword.pop(env, :resources, [])
    {default, env} = Keyword.pop(env, :default_resource)

    env
    |> Keyword.merge(
      name: Issuer,
      issuer: issuer(),
      resources: Enum.map(modules, & &1.options()),
      default_resource: default && default.options()[:id]
    )
    |> Config.new!()
  end

  @doc """
  The issuer identifier (RFC 8414), which is also the audience of client
  assertions. Defaults to the endpoint's public URL.
  """
  def issuer do
    Keyword.get(Application.get_env(:reviews, __MODULE__, []), :issuer) ||
      ReviewsWeb.Endpoint.url()
  end

  @doc "Every configured `Reviews.OAuth.Resource` module, enabled or not."
  def resources, do: Keyword.get(Application.get_env(:reviews, __MODULE__, []), :resources, [])

  @doc "The resource module of a `Gatekeep.Resource` or resource identifier, or nil."
  def resource_module(%Resource{id: id}), do: resource_module(id)

  def resource_module(id) when is_binary(id) do
    case Config.resource(config(), id) do
      nil -> nil
      resource -> Enum.find(resources(), &(&1.options()[:id] == resource.id))
    end
  end

  ## Authorization

  @doc """
  The owner approves a checked authorization `request` for one of their agent
  identities. Returns the redirect back to the client, which carries the
  code. The identity must be an agent that belongs to `user`; the owner's
  human identity and any other ID are refused, so an OAuth app never acts as
  the person. `granted_scopes` must be a non-empty subset of the request's.
  """
  @spec approve(User.t(), term(), Authorization.request(), [String.t()]) ::
          {:ok, String.t()} | {:error, :invalid_identity}
  def approve(%User{} = user, identity_id, request, granted_scopes) do
    with {:ok, id} when is_integer(id) <- Ecto.Type.cast(:id, identity_id),
         %Identity{kind: "agent"} = identity <- Accounts.get_owned_identity(user, id),
         {:ok, url} <-
           Authorization.approve(config(), request,
             subject: identity.id,
             owner: user.id,
             scopes: granted_scopes
           ) do
      {:ok, url}
    else
      _ -> {:error, :invalid_identity}
    end
  end

  ## Protected resources

  @doc """
  Authenticates a request's access token at the resource `resource_id`
  (`Gatekeep.Token.authenticate/3`): unexpired, its grant active, issued for
  this resource, its client not blocked, and, when DPoP-bound, sent with a
  proof from its key. `request` holds the `:authorization` header, every
  `:dpop` header value, the `:method`, and the `:path`.

  Returns the grant, with the agent identity it acts as and the person who
  approved it, and the token.
  """
  @spec authenticate_access_token(String.t(), Token.request()) ::
          {:ok, %{grant: Grant.t(), token: Token.t()}}
          | {:error, :missing_token | :invalid_token | :invalid_dpop_proof}
  def authenticate_access_token(resource_id, request) do
    with {:ok, token} <- Token.authenticate(config(), resource_id, request) do
      case token.grant_id && Repo.get(Grant, token.grant_id) |> with_people() do
        %Grant{identity: %Identity{}, approved_by_user: %User{}} = grant ->
          {:ok, %{grant: grant, token: token}}

        _ ->
          {:error, :invalid_token}
      end
    end
  end

  ## Metadata

  @doc """
  Authorization server metadata (RFC 8414): gatekeep's, plus the enabled
  resources as `protected_resources` (RFC 9728 §4) and the fields each
  resource module adds.
  """
  def authorization_server_metadata do
    config = config()
    enabled = Config.enabled_resources(config)

    enabled
    |> Enum.map(&resource_module/1)
    |> Enum.filter(&(&1 && function_exported?(&1, :authorization_server_metadata, 0)))
    |> Enum.reduce(
      config
      |> Metadata.authorization_server()
      |> Map.put("protected_resources", Enum.map(enabled, & &1.id)),
      fn module, acc ->
        Map.merge(acc, Map.new(module.authorization_server_metadata(), &key/1))
      end
    )
  end

  defp key({key, value}), do: {to_string(key), value}

  @doc """
  Protected resource metadata (RFC 9728) of the enabled resource whose
  metadata lives at `path`, such as `/.well-known/oauth-protected-resource`
  for a resource at the root, or nil.
  """
  def protected_resource_metadata(path) do
    config = config()

    case Enum.find(Config.enabled_resources(config), &(Resource.metadata_path(&1) == path)) do
      nil -> nil
      resource -> Metadata.protected_resource(config, resource)
    end
  end

  ## Owner management

  @doc "Active and revoked grants the user approved, newest first, with their agent identities."
  def list_grants_for(%User{id: user_id}) do
    config()
    |> Gatekeep.list_grants(owner: to_string(user_id))
    |> Enum.map(&(Grant |> struct(&1) |> with_people()))
  end

  @doc "The owner revokes a grant. Unknown and unowned IDs return the same error."
  def revoke_grant(%User{} = user, id) do
    with {grant_id, ""} <- Integer.parse(to_string(id)),
         %Grant{} <- Enum.find(list_grants_for(user), &(&1.id == grant_id)) do
      Gatekeep.revoke_grant(config(), grant_id)
    else
      _ -> {:error, :not_found}
    end
  end

  # The agent identity a grant acts as (its subject) and the person who
  # approved it (its owner).
  defp with_people(%Grant{} = grant) do
    %{
      grant
      | identity: get(Identity, grant.subject),
        approved_by_user: get(User, grant.owner)
    }
  end

  defp with_people(nil), do: nil

  defp get(schema, id) do
    case is_binary(id) && Integer.parse(id) do
      {id, ""} -> Repo.get(schema, id)
      _ -> nil
    end
  end
end
