defmodule Reviews.OAuth.Resource do
  @moduledoc """
  An API that accepts access tokens from the Reviews issuer: a protected
  resource (RFC 9728) with its own identifier (RFC 8707) and scopes.

  List each one under `config :reviews, Reviews.OAuth, resources: [...]`.
  The `resource` parameter of an authorization request names the resource.
  Each grant is for one resource, and its tokens are accepted only by that
  resource (`Reviews.OAuth.authenticate_access_token/2`), so a token issued
  for one API is refused by another.
  """

  @doc """
  The resource's gatekeep options (see `Gatekeep.Config`, `:resources`):
  `:id`, the identifier and audience of its tokens; `:scopes`, as
  `{name, description}` in the order the consent page and metadata list
  them; `:default_scopes` for a request without `scope` (`[]` refuses such a
  request); `:client_auth_methods`; `:rotate_refresh_tokens`; `:dpop`;
  `:enabled`; `:name`; and `:metadata` for its protected resource metadata.
  """
  @callback options() :: keyword()

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

  @doc "Fields this resource adds to the issuer's metadata (RFC 8414 §2)."
  @callback authorization_server_metadata() :: map()

  @optional_callbacks authorization_server_metadata: 0
end
