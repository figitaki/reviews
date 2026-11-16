defmodule Reviews.OAuth.Resource do
  @moduledoc """
  An API that accepts access tokens from the Reviews issuer: a protected
  resource (RFC 9728) with its own identifier (RFC 8707) and scopes.

  List each one under `config :reviews, Reviews.OAuth, resources: [...]`. The
  `resource` parameter of an authorization request names the resource. Each
  grant is an `Reviews.Accounts.IdentityLink` whose `provider` is the
  resource's, and its tokens are accepted only by that resource
  (`Reviews.OAuth.authenticate_access_token/2`), so a token issued for one API
  is refused by another.
  """

  @doc "The `provider` of this resource's identity links, such as `\"mcp\"`."
  @callback provider() :: String.t()

  @doc "The resource identifier (RFC 8707) and audience of its tokens."
  @callback resource() :: String.t()

  @doc "Whether the issuer currently grants tokens for this resource."
  @callback enabled?() :: boolean()

  @doc "Every scope this resource offers, with the description the consent page shows."
  @callback scopes() :: %{String.t() => String.t()}

  @doc "The scope names in the order the consent page and metadata list them."
  @callback scope_names() :: [String.t()]

  @doc """
  Parses a requested scope string. `nil` is a request without `scope`.
  Returns `:error` for scopes this resource doesn't offer.
  """
  @callback parse_scopes(String.t() | nil) :: {:ok, [String.t()]} | :error

  @doc """
  Token endpoint authentication methods a client may use to get and refresh
  this resource's tokens: `"private_key_jwt"`, and `"none"` for public
  clients that rely on PKCE alone.
  """
  @callback client_auth_methods() :: [String.t()]

  @doc """
  Whether refresh tokens rotate on every use. Reusing a replaced refresh
  token then revokes the grant (OAuth 2.1 §4.3.1).
  """
  @callback rotate_refresh_tokens?() :: boolean()

  @doc """
  The text of the sign-in and consent pages. `client_label` names the client:
  its verified domain, or what a registered client calls itself.
  """
  @callback consent_text(client_label :: String.t()) :: %{
              eyebrow: String.t(),
              title: String.t(),
              sign_in: String.t(),
              description: String.t(),
              note: String.t()
            }

  @doc "Fields added to this resource's protected resource metadata (RFC 9728 §2)."
  @callback protected_resource_metadata() :: map()

  @doc "Fields this resource adds to the issuer's metadata (RFC 8414 §2)."
  @callback authorization_server_metadata() :: map()

  @doc """
  DPoP proof algorithms (RFC 9449) this resource accepts. A resource that
  lists any gets tokens bound to the key of a token request's proof.
  """
  @callback dpop_signing_algs() :: [String.t()]

  @optional_callbacks protected_resource_metadata: 0,
                      authorization_server_metadata: 0,
                      dpop_signing_algs: 0
end
