# Hosted MCP (prototype)

Reviews serves a [Model Context Protocol](https://modelcontextprotocol.io)
endpoint at `/mcp` from the Phoenix app, using
[FastestMCP](https://hex.pm/packages/fastest_mcp) over Streamable HTTP. It
supports MCP protocol revisions `2026-07-28` and `2025-11-25`.

This is the first slice of #95 (#108, #111 and #112 in part). It reuses the
existing API tokens. OAuth discovery, consent and client credentials (#109,
#110) are not built yet, so clients that only connect through OAuth, such as
Claude.ai custom connectors, cannot use it.

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

Send a Reviews API token as a bearer token, the same token the CLI uses:

```
Authorization: Bearer rev_...
```

Mint one in Settings. Mint it for an agent identity so the agent's comments
and pushes are attributed to it. The token is checked on every request, so a
revoked token stops working on its next call.

Tokens have no scope model yet. Every valid token holds `reviews:read`,
`reviews:write` and `threads:write`. The tools already check those scopes, so
OAuth tokens can narrow them later.

MCP follows the same permission rules as the web page, REST and Poppy
(`Reviews.Policy`, listed in `docs/CONTRACTS.md`). A token can read any review
whose slug or URL it has, and comment on it. Only the review owner's account can
push revisions, and only the owner or a thread's author can resolve or reopen a
thread. Anyone else gets an error result, and nothing is written.

## Tools

Reviews are named by slug (`k7m2qz`) or URL (`https://host/r/k7m2qz`).
`revision` defaults to the latest; a revision that does not exist is an error,
never silently replaced by the latest.

Every read fits in `max_bytes` (default 40,000, from 2,000 to 120,000), counting
metadata and both copies of the result: the structured content and its JSON
text. Lists and long text continue with `next_cursor` (or `next_offset` for
file diffs). Send it back with the `revision` of the page it came from; a
continuation without a revision is refused, so pages from two revisions are
never mixed. Cursors are opaque strings such as `c40` or `c3.8892`; pass
`next_cursor` back unchanged. They always start with a letter, so no client can
read one as a number. They are plain positions, not signed tokens, and every
page is authorized again. Reads load only what the page needs; they do not assemble
the whole review.

| Tool | Does |
|---|---|
| `reviews_whoami` | The token's identity (human or agent) and whether writes are on. |
| `reviews_get_review` | Title, URL, thread counts, description and packet summary, packet outline, then revisions with stats, newest first. |
| `reviews_get_packet_section` | One section's rows in reading order: Markdown prose and hunk diffs. A row with `complete: false` continues on the next page. |
| `reviews_list_files` | Files in a revision, in path order, with status, line counts, size and open threads. |
| `reviews_get_file_diff` | One file's diff in pieces; continue with `next_offset` and the same `revision`. |
| `reviews_list_threads` | Threads projected onto a revision, with their first comments. `line` is null when the code changed (`anchor_status: "outdated"`). `comments_complete: false` means more comments or longer bodies than shown. |
| `reviews_get_thread` | One thread with all of its comments, in pieces when long. |
| `reviews_create_review` | Publish a review from a unified diff and optional packet JSON. Hunk rows and `line_start`/`line_end` slices are checked against the diff, as the CLI does. |
| `reviews_append_revision` | Upload a new revision of a review your account owns, with the same checks. |
| `reviews_post_comment` | Reply with `thread_id`, or start a thread at `path` + `line` of a revision's diff. The line must be in that revision's diff. |
| `reviews_update_thread_status` | Resolve or reopen a thread. |

Resource: `reviews://{slug}/feedback`, the open threads of the latest revision
as Markdown anchored to `path:line`. It shows at most 50 threads and 60 KB, and
says how many threads it left out; read those with `reviews_list_threads`.

Prompt: `address_feedback`, which walks an agent through reading, fixing,
replying to and resolving open threads.

Writes publish immediately and are not idempotent. Clients should not retry a
write after a timeout without reading first (#151 tracks durable
deduplication). `reviews_post_comment` binds a new thread to the revision it
names, but does not check atomically against a concurrent push (#150).

## Connecting a client

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

MCP Inspector, to check the connection:

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

OAuth and client credentials (#109, #110), section decisions, account-wide
review listing, per-request audit logs beyond FastestMCP telemetry, and the
local `reviews mcp` stdio server (#94).
