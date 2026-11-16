# Hosted MCP (prototype)

Reviews serves a [Model Context Protocol](https://modelcontextprotocol.io)
endpoint at `/mcp` from the Phoenix app, using
[FastestMCP](https://hex.pm/packages/fastest_mcp) over Streamable HTTP. It
supports MCP protocol revisions `2026-07-28` and `2025-11-25`.

This is the first slice of #95 (#108, #111 and #112 in part, and #109).
Clients connect either with an existing API token or by signing in with OAuth,
which is how Claude custom connectors and ChatGPT connect. Client credentials
for unattended agents (#110) are not built yet.

## Turning it on

The endpoint and the write tools are off unless configured.

| Environment | Endpoint | Writes |
|---|---|---|
| dev, test | on | on |
| prod | `MCP_ENABLED=true` | also `MCP_WRITES_ENABLED=true` |
| Fly previews | on (`fly.preview.toml`) | on |

With the endpoint off, `/mcp` returns 404. Requests for another host get 403;
`/mcp` is never redirected to the canonical host, so a client is not sent
elsewhere with its token. Each identity may make 5 requests a second, with
bursts of 20. With writes off, the write tools are
not listed and are refused on every call, including from clients that cached
an older tool list. Requests must use the host in `PHX_HOST`; browser requests
from other origins are rejected. MCP request bodies are capped at 4 MB before
JSON decoding. The CLI's 50 MB REST limit is unchanged.

## Authentication and access

There are two kinds of bearer token: an OAuth access token from signing in, or
a Reviews API token.

### OAuth (Claude, ChatGPT, MCP Inspector)

A request without a valid token gets 401 with:

```
WWW-Authenticate: Bearer resource_metadata="https://HOST/.well-known/oauth-protected-resource/mcp",
  scope="reviews:read reviews:write threads:write"
```

That document (RFC 9728) names `https://HOST/mcp` as the resource and the
Reviews issuer, `https://HOST`, as its authorization server. The issuer's
metadata is at `/.well-known/oauth-authorization-server` (RFC 8414). It is the
Reviews OAuth issuer (`Reviews.OAuth`), shared with any other API that takes
its tokens; the `resource` parameter (RFC 8707) picks the API, and a token for
one API is refused by every other.

The issuer supports:

| Need | How |
|---|---|
| Authorization code with PKCE | `S256` only. `iss` is on every redirect back (RFC 9207), errors included. |
| Client ID metadata documents | An HTTPS `client_id` is fetched (HTTPS only, no redirects, no private addresses, 100 KB, 5 s, cached 5 minutes). Redirect URIs must be on the `client_id` host or loopback. Claude's is `https://claude.ai/oauth/mcp-oauth-client-metadata`; ChatGPT's is `https://chatgpt.com/oauth/client.json`. |
| Dynamic client registration | `POST /oauth/register` (RFC 7591) registers a public client: HTTPS, loopback, or app-scheme redirect URIs, `token_endpoint_auth_method` `none`. The MCP Inspector and Codex use this. |
| Client authentication | `none` (public clients, PKCE alone) or `private_key_jwt` (ES256, PS384, RS256) for clients whose metadata has a `jwks_uri`. The assertion's `aud` is the issuer; ChatGPT's client ID may also use the token endpoint, as ChatGPT does. |
| Refresh | Access tokens last an hour. Refresh tokens rotate on every use, and presenting a replaced one revokes the grant. A grant lasts 90 days. |
| Revocation | `POST /oauth/revoke` (RFC 7009), or Disconnect in Settings. Either stops the grant's tokens on their next request. |

Scopes:

| Scope | Allows |
|---|---|
| `reviews:read` | Every read tool, `search`, `fetch`, the feedback resource and the prompt. |
| `reviews:write` | `reviews_create_review`, `reviews_append_revision`. |
| `threads:write` | `reviews_post_comment`, `reviews_update_thread_status`. |

Tools a token lacks the scope for are not listed. Calling one gets 403 with an
`insufficient_scope` challenge naming the scope, so a client can ask for it.

Signing in sends the owner to `/oauth/authorize`. After GitHub sign-in, the
consent page shows the client's verified domain (or says it has none, for a
registered client), the host it returns to, a warning for loopback redirects,
and the scopes. The owner picks which identity the client acts as: one of
their agents (listed first) or themselves. A scope permission never widens
access: OAuth tokens, like API tokens, reach only the account's own reviews.

### API tokens

Send a Reviews API token as a bearer token, the same token the CLI uses:

```
Authorization: Bearer rev_...
```

Mint one in Settings. Mint it for an agent identity so the agent's comments
and pushes are attributed to it. The token is checked on every request, so a
revoked token stops working on its next call.

API tokens have no scope model yet. Every valid API token holds
`reviews:read`, `reviews:write` and `threads:write`.

### Access

A token of either kind can read and write only the reviews its account owns: reviews pushed by
the account's human identity or any of its agent identities. Reviews owned by
other accounts get the same "not found" result as unknown slugs, even though
the web link is public. This follows #107 ("a slug is not a grant"). It means a
reviewer's agent cannot read a review that someone else shared with them yet.

## Tools

Reviews are named by slug (`k7m2qz`) or URL (`https://host/r/k7m2qz`).
`revision` defaults to the latest; a revision that does not exist is an error,
never silently replaced by the latest.

Every read fits in `max_bytes` (default 40,000, from 2,000 to 120,000), counting
metadata and both copies of the result: the structured content and its JSON
text. Lists and long text continue with `next_cursor` (or `next_offset` for
file diffs). Send it back with the `revision` of the page it came from; a
continuation without a revision is refused, so pages from two revisions are
never mixed. Cursors are plain positions, not signed tokens, and every page is
authorized again. Reads load only what the page needs; they do not assemble
the whole review.

| Tool | Does |
|---|---|
| `search` | Reviews this account owns whose title, description or slug contains `query`, as `{results: [{id, title, url}]}`, the shape ChatGPT connectors and deep research use. A blank query lists the newest. |
| `fetch` | One review by the `id` from `search` (its slug): `{id, title, text, url, metadata}`, where `text` is the description and the open feedback as Markdown. The result fits in 120,000 bytes. `metadata.complete` is false when anything is left out: a longer review is cut short with a note, and left-out threads or comments are named in the feedback. |
| `reviews_whoami` | The token's identity (human or agent), its scopes, and whether writes are on. |
| `reviews_get_review` | Title, URL, thread counts, description and packet summary, packet outline, then revisions with stats, newest first. |
| `reviews_get_packet_section` | One section's rows in reading order: Markdown prose and hunk diffs. A row with `complete: false` continues on the next page. |
| `reviews_list_files` | Files in a revision, in path order, with status, line counts, size and open threads. |
| `reviews_get_file_diff` | One file's diff in pieces; continue with `next_offset` and the same `revision`. |
| `reviews_list_threads` | Threads projected onto a revision, with their first comments. `line` is null when the code changed (`anchor_status: "outdated"`). `comments_complete: false` means more comments or longer bodies than shown. |
| `reviews_get_thread` | One thread with all of its comments, in pieces when long. |
| `reviews_create_review` | Publish a review from a unified diff and optional packet JSON. Hunk rows and `line_start`/`line_end` slices are checked against the diff, as the CLI does. |
| `reviews_append_revision` | Upload a new revision of an owned review, with the same checks. |
| `reviews_post_comment` | Reply with `thread_id`, or start a thread at `path` + `line` of a revision's diff. The line must be in that revision's diff. |
| `reviews_update_thread_status` | Resolve or reopen a thread. |

Resource: `reviews://{slug}/feedback`, the open threads of the latest revision
as Markdown anchored to `path:line`. It shows at most 50 threads and 60 KB, and
says how many threads it left out; read those with `reviews_list_threads`.

Prompt: `address_feedback`, which walks an agent through reading, fixing,
replying to and resolving open threads.

Every tool sets `readOnlyHint`, `destructiveHint` and `openWorldHint`
explicitly, as ChatGPT's app review asks. Writes add to a review and never
delete, so none is destructive. Each tool's `_meta.securitySchemes` names the
OAuth scope it needs.

Writes publish immediately and are not idempotent. Clients should not retry a
write after a timeout without reading first (#151 tracks durable
deduplication). `reviews_post_comment` binds a new thread to the revision it
names, but does not check atomically against a concurrent push (#150).

## Connecting a client

### Claude (custom connector)

In Claude, Settings → Connectors → Add custom connector, enter
`https://HOST/mcp` and leave the OAuth client settings empty. Claude uses its
client metadata document and returns to `https://claude.ai/api/mcp/auth_callback`.
Sign in with GitHub on the Reviews page it opens, pick an identity and scopes,
and Allow. Claude's traffic comes from `160.79.104.0/21`.

### ChatGPT (developer mode connector or app)

In ChatGPT, with developer mode on, create a connector with
`https://HOST/mcp` and OAuth. ChatGPT uses `https://chatgpt.com/oauth/client.json`
with `private_key_jwt` and returns to
`https://chatgpt.com/connector_platform_oauth_redirect`. Its `search` and
`fetch` tools work for deep research. Choosing DCR in ChatGPT works too.

### Bearer-token clients

Replace `HOST` with the server, such as `reviews-pr-<N>.fly.dev` for a preview,
and `TOKEN` with an API token for that server. On previews, use the
`PREVIEW_API_TOKEN` value (see `docs/PREVIEW_ENVS.md`), since GitHub sign-in
does not work on preview hosts.

Claude Code:

```sh
claude mcp add --transport http reviews https://HOST/mcp \
  --header "Authorization: Bearer TOKEN"
```

Amp (stored on ampcode.com, so it also works in orbs; the token is read from
standard input):

```sh
printf %s "TOKEN" | amp mcp remote --personal add reviews https://HOST/mcp \
  --auth bearer --bearer-token-file -
```

Or in `~/.config/amp/settings.json`, with the token in an environment variable:

```json
"amp.mcpServers": {
  "reviews": {
    "url": "https://HOST/mcp",
    "headers": { "Authorization": "Bearer ${REVIEWS_MCP_TOKEN}" }
  }
}
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.reviews]
url = "https://HOST/mcp"
bearer_token_env_var = "REVIEWS_MCP_TOKEN"
```

MCP Inspector, to check the connection. The web UI
(`npx @modelcontextprotocol/inspector`) signs in with OAuth through dynamic
registration when you add `https://HOST/mcp` as a streamable-http server. The
CLI takes a token:

```sh
npx @modelcontextprotocol/inspector --cli https://HOST/mcp --transport http \
  --header "Authorization: Bearer TOKEN" --method tools/list
```

## Things to try

1. "Who am I on Reviews?" (`reviews_whoami`)
2. "Create a Reviews review of `git diff HEAD~1` titled 'Try MCP'." The agent
   calls `reviews_create_review` and returns a link.
3. "Comment on line 3 of `<file>` in that review: 'Why this name?'"
4. "Read the open feedback on `<slug>` and reply to each thread." (or the
   `address_feedback` prompt)
5. "Resolve thread `<id>`." Then open the review link to see the agent's
   replies and the resolved thread in the UI.

## Not in this slice

Client credentials (#110), section decisions, per-request audit logs beyond
FastestMCP telemetry (the OAuth client ID is on each request's principal but
not logged), an Apps SDK / MCP Apps widget, labels on comments posted through
OAuth naming the client, and the local `reviews mcp` stdio server (#94).
Registered clients are never deleted, and registration has no rate limit of
its own.
