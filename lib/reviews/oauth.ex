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
    * The one exception is the Reviews CLI (`Reviews.OAuth.CLI`): its own
      client signs in with the device authorization grant, the person
      approves it at `/device` (`approve_device/3`), choosing which of their
      identities it acts as: their human identity, as API tokens do, or one
      of their agents. Only the CLI resource accepts a human subject.

  `config/0` builds the gatekeep config from `config :reviews, Reviews.OAuth`
  on every call, because the issuer defaults to the endpoint's public URL and
  the resources derive their identifiers from it. Besides `:resources` and
  `:default_resource` (modules here), the keys are `Gatekeep.Config` options.
  """

  alias Gatekeep.{Authorization, Config, DeviceAuthorization, Metadata, Resource, Token}
  alias Reviews.Accounts
  alias Reviews.Accounts.{Identity, User}
  alias Reviews.OAuth.{CLI, Grant, Issuer}
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

    # The CLI resource brings its own client.
    clients = Keyword.get(env, :clients, []) ++ if(CLI in modules, do: [CLI.client()], else: [])

    env
    |> Keyword.merge(
      name: Issuer,
      issuer: issuer(),
      resources: Enum.map(modules, & &1.options()),
      default_resource: default && default.options()[:id],
      clients: clients
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

  @doc """
  Creates an agent identity for `user` from `attrs` (`handle`,
  `display_name`), as Settings does, and approves `request` for it, in one
  transaction: if either step fails, neither is kept. Returns the redirect
  back to the client,
  `{:error, changeset}` when the identity is not valid, or
  `{:error, :invalid_identity}` when the approval is refused.
  """
  @spec approve_new_agent(User.t(), map(), Authorization.request(), [String.t()]) ::
          {:ok, String.t()} | {:error, Ecto.Changeset.t() | :invalid_identity}
  def approve_new_agent(%User{} = user, attrs, request, granted_scopes) when is_map(attrs) do
    Repo.transaction(fn ->
      with {:ok, identity} <-
             Accounts.create_agent_identity(user, Map.take(attrs, ["handle", "display_name"])),
           {:ok, url} <- approve(user, identity.id, request, granted_scopes) do
        url
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  ## Device sign-in (the Reviews CLI)

  @doc """
  The pending CLI sign-in with `user_code`, for `/device`. Only requests for
  the CLI resource can be approved here; any other is `:invalid_user_code`.
  """
  @spec lookup_device(term()) ::
          {:ok, DeviceAuthorization.request()} | {:error, :invalid_user_code | :expired_user_code}
  def lookup_device(user_code) do
    with {:ok, request} <- DeviceAuthorization.lookup(config(), user_code) do
      if Gatekeep.Util.same_url?(request.resource.id, CLI.id()),
        do: {:ok, request},
        else: {:error, :invalid_user_code}
    end
  end

  @doc """
  `user` approves the CLI sign-in with `user_code`, acting as `identity_id`:
  the user's human identity or one of their agents. Any other ID is
  `:invalid_identity`. The user owns the grant.
  """
  @spec approve_device(User.t(), term(), term()) ::
          :ok | {:error, :invalid_user_code | :expired_user_code | :invalid_identity}
  def approve_device(%User{} = user, user_code, identity_id) do
    with {:ok, _request} <- lookup_device(user_code),
         {:ok, identity} <- owned_identity(user, identity_id) do
      case DeviceAuthorization.approve(config(), user_code, subject: identity.id, owner: user.id) do
        {:error, :invalid_scopes} -> {:error, :invalid_user_code}
        result -> result
      end
    end
  end

  defp owned_identity(user, identity_id) do
    with {:ok, id} when is_integer(id) <- Ecto.Type.cast(:id, identity_id),
         %Identity{} = identity <- Accounts.get_owned_identity(user, id) do
      {:ok, identity}
    else
      _ -> {:error, :invalid_identity}
    end
  end

  @doc "`user` denies the CLI sign-in with `user_code`; the CLI stops waiting."
  @spec deny_device(term()) :: :ok | {:error, :invalid_user_code | :expired_user_code}
  def deny_device(user_code) do
    with {:ok, _request} <- lookup_device(user_code) do
      DeviceAuthorization.deny(config(), user_code)
    end
  end

  @doc """
  Authenticates a CLI access token at `/api/v1`. Returns the person and the
  identity they chose at `/device`, as `Reviews.Accounts.authenticate_token/1`
  does for API tokens.
  """
  @spec authenticate_cli_token(Token.request()) ::
          {:ok, %{user: User.t(), identity: Identity.t()}} | {:error, atom()}
  def authenticate_cli_token(request) do
    with {:ok, %{grant: grant}} <- authenticate_access_token(CLI.id(), request) do
      {:ok, %{user: grant.approved_by_user, identity: grant.identity}}
    end
  end

  ## Protected resources

  @doc """
  Authenticates a request's access token at the resource `resource_id`
  (`Gatekeep.Token.authenticate/3`): unexpired, its grant active, issued for
  this resource, its client not blocked, and, when DPoP-bound, sent with a
  proof from its key. `request` holds the `:authorization` header, every
  `:dpop` header value, the `:method`, and the `:path`.

  Returns the grant, with the identity it acts as and the person who
  approved it, and the token. The identity belongs to that person; it may be
  their human identity only at the CLI resource, and is one of their agents
  everywhere else.
  """
  @spec authenticate_access_token(String.t(), Token.request()) ::
          {:ok, %{grant: Grant.t(), token: Token.t()}}
          | {:error, :missing_token | :invalid_token | :invalid_dpop_proof}
  def authenticate_access_token(resource_id, request) do
    with {:ok, token} <- Token.authenticate(config(), resource_id, request) do
      human_ok? = Gatekeep.Util.same_url?(token.resource, CLI.id())

      case token.grant_id && Repo.get(Grant, token.grant_id) |> with_people() do
        %Grant{
          identity: %Identity{kind: kind, owner_user_id: user_id},
          approved_by_user: %User{id: user_id}
        } = grant
        when kind == "agent" or (kind == "human" and human_ok?) ->
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
