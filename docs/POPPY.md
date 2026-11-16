# Reviews as a Poppy Company (merchant identity)

Reviews implements the Company side of the
[Personal Agent Protocol 1.0](https://personalagentprotocol.org/docs/1.0/spec) ("Poppy") for one
operation: a Personal Agent posts a review comment as a Reviews agent identity that its owner approved.
This is the first milestone of issue #154. Payments (#145) are out of scope.

The CLI and bearer-token API under `/api/v1` are unchanged. Poppy uses its own routes and tokens, and
neither kind of token works on the other's routes.

## Identity model

| Party | How Reviews knows it | Shown as verified? |
| --- | --- | --- |
| Reviews identity (actor) | Existing `identities` row. Comments keep its `author_id`. | Yes: the author |
| Owner | GitHub user who approved the link on the consent page | Yes: "Owner … approved this agent" |
| Personal Agent | `client_id` URL. Session JWTs verify against keys from its `jwks_uri`. | Yes: its domain only |
| Personal Agent's name | `client_name` in its metadata | No: "Calls itself … (not verified)" |
| Agent ID (`agent_id` claim) | Signed by the Personal Agent, but it chooses the value | No: "sent (not verified)" |
| Execution workload | Poppy 1.0 has no proof of it | "not established" |
| Delegation chain | Poppy 1.0 has none. Approval happens in Reviews. | "owner approval in Reviews" |

The approval is an `identity_links` row: `(identity_id, approved_by_user_id, provider: "poppy",
subject: client_id, scopes)`. It never creates an identity. A DID or Turnkey-held key adds rows with
another `provider` through the `Reviews.ExternalIdentity` behaviour, so actor IDs stay the same
(see "Adding other verification methods").

## Endpoints

| Path | Purpose |
| --- | --- |
| `GET /.well-known/poppy.json` | Discovery (spec 3) |
| `GET /.well-known/oauth-protected-resource` | RFC 9728. Names the issuer. |
| `GET /.well-known/oauth-authorization-server` | RFC 8414. Lists the domain in `protected_resources`. |
| `GET /api/poppy/openapi.json` | OpenAPI 3.1 description of the Poppy API |
| `GET /oauth/authorize`, `POST /oauth/authorize` | Direct Sign-In: GitHub sign-in, then a consent page where the owner picks one of their agent identities |
| `POST /oauth/token` | `authorization_code` (PKCE S256) and `refresh_token`. `private_key_jwt` client assertion (ES256 or PS384, `aud` = issuer). |
| `POST /oauth/revoke` | RFC 7009. Revoking the refresh token revokes the link and its access tokens. |
| `GET /api/poppy/v1/reviews/:slug` | Read a review. Works signed out with a verified Session header. |
| `POST /api/poppy/v1/reviews/:slug/comments` | Post a comment. Needs an access token with `comments:write`. |

The issuer is `config :reviews, Reviews.OAuth, issuer:` (`Reviews.OAuth`, shared with other OAuth
APIs), which defaults to the endpoint URL. In development set `OAUTH_ISSUER` to an HTTPS origin
that reaches the server.

## What each request must pass

`ReviewsWeb.Plugs.PoppyAuth` calls `Reviews.Poppy.Adapter`, which checks these in order:

1. `Poppy-Version` is `1.x`. Otherwise 400 `version_unsupported`.
2. The `Poppy-Session` JWT has `typ` `poppy-session+jwt`, `alg` ES256, and a `poppy_dlg` delegation.
3. The client metadata at `iss` is fetched without redirects, over HTTPS, and never from private
   addresses. Its `client_id` must equal the URL, and its `jwks_uri` and `redirect_uris` must be on
   the same host.
4. The delegation verifies (ES256 or PS384) with the `jwks_uri` key its `kid` names. It also needs
   the right `typ`, `iss` equal to the JWT's, an unexpired `exp`, and a lifetime of at most 24 hours.
5. The JWT verifies with the delegation's `cnf.jwk`, and its `kid` is that key's thumbprint.
6. `aud` equals the issuer character for character. `htm` and `htu` match the request, and `htu` is
   compared against the configured public origin, never the `Host` header. `iat` must fall within 60
   seconds, plus 30 seconds of clock skew.
7. `jti` hasn't been seen. The replay cache is the `poppy_seen_jtis` table, shared by every server.
8. With an access token, `ath` must match it. The token must be unexpired, its link not revoked, and
   the link's `subject` equal to the JWT's `iss`. Without a token, `ath` must be absent.
9. The Session (`client_id`, `sid`, `sub`) is created or continued. It can't switch to another
   identity (`session_ended`) or change `agent_id`.

Every other failure is 400 `invalid_session` with no reason in the body. Access-token problems
return 401 `invalid_token` in `WWW-Authenticate`. A signed-out request to the comment endpoint gets
401 with `Bearer scope="comments:write"`.

## Revocation

- **Owner:** Settings → Connected agents → Disconnect. Access and refresh tokens stop on the next request.
- **Agent:** `POST /oauth/revoke` with the refresh token (sign-out).
- **Reused code:** redeeming an authorization code twice revokes the link it created.
- **Personal Agent key:** after removal from `jwks_uri`, the key stops verifying once the
  client cache expires (`client_cache_seconds`, default 300) or `Reviews.OAuth.Clients.forget/1` runs.
  Delegations can't be withdrawn early (spec 10.7).
- **Block a client:** `config :reviews, Reviews.OAuth, blocked_clients: [client_id]`.

Earlier comments keep their attribution. Their details then say "since disconnected".

## Trying it

`examples/poppy-agent/` is a dependency-free Node Personal Agent, with instructions in its README.
To check a deployment with the official validator:

```sh
git clone https://github.com/personal-agent-protocol/personal-agent-protocol
cd personal-agent-protocol
node kit/company/validate/index.ts keygen --base-url https://<where you host agent.json>
node kit/company/validate/index.ts check https://<reviews host> --milestone foundation \
  --probe https://<reviews host>/api/poppy/v1/reviews/<slug> --probe-session
```

## Adding other verification methods

Implement `Reviews.ExternalIdentity.authenticate/2` and resolve to an `IdentityLink` with a new
`provider` (`"turnkey"`, `"did"`). Store what was verified in `attribution`, using the Poppy
adapter's map as the shape, and leave parties you can't verify unset or mark them as claims. Owner
approval, revocation, and the UI label stay the same. Reviews actor IDs don't change.
