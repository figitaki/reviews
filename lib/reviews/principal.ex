defmodule Reviews.Principal do
  @moduledoc """
  The authenticated caller of any surface: who acts, for which account, with
  which scopes, and how the request was verified.

  Every surface builds one: `ReviewsWeb.Plugs.RequireApiToken` for REST and
  the CLI, `ReviewsWeb.Plugs.PoppyAuth` for Poppy, and the MCP handlers from
  the verified MCP principal. Context functions take a principal (or a bare
  `Identity`, as the web page passes) and `Reviews.Policy` decides with it.

    * `identity` - the identity that acts and is recorded as author.
    * `user` - the account that owns the identity; may be nil when unknown.
    * `scopes` - `:all` for API tokens and web sessions, or the granted
      OAuth scope names.
    * `attribution` - verification facts stored with comments, such as a
      Poppy delegation; nil otherwise.
    * `via` - how the caller signed in: `:session`, `:api_token`, `:poppy`,
      or `:mcp`.
  """
  alias Reviews.Accounts.{Identity, User}

  @enforce_keys [:identity, :via]
  defstruct [:identity, :user, :attribution, :via, scopes: :all]

  @type t :: %__MODULE__{
          identity: Identity.t(),
          user: User.t() | nil,
          scopes: :all | [String.t()],
          attribution: map() | nil,
          via: :session | :api_token | :poppy | :mcp
        }

  @doc "A principal with every scope, for an API token or a signed-in web session."
  def new(%Identity{} = identity, via \\ :session, user \\ nil),
    do: %__MODULE__{identity: identity, user: user, via: via}

  @doc "A principal from an OAuth grant, limited to its `scopes`."
  def delegated(%Identity{} = identity, user, scopes, attribution, via) when is_list(scopes),
    do: %__MODULE__{
      identity: identity,
      user: user,
      scopes: scopes,
      attribution: attribution,
      via: via
    }

  @doc """
  Wraps a bare identity and passes principals through. Anything else, such as
  nil for a signed-out reader, is not a principal and gets nil.
  """
  def from(%__MODULE__{} = principal), do: principal
  def from(%Identity{} = identity), do: new(identity)
  def from(_other), do: nil

  @doc "True when the principal was granted `scope` (always, for `:all`)."
  def scope?(%__MODULE__{scopes: :all}, _scope), do: true
  def scope?(%__MODULE__{scopes: scopes}, scope), do: scope in scopes
end
