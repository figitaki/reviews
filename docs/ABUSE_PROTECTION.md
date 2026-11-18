# Application request budgets

This is a first application-level defense, not DDoS protection or a measured safe
request rate. It does not change Fly networking, deployment settings, or seeded
demos. Before deploying, resolve the client-IP trust prerequisite below and
measure normal traffic and memory use, especially large uploads.

## Admission and body handling

`Endpoint.call/2` runs cheap admission before Phoenix socket dispatch, static
files, sessions, token queries, and body parsing. Each request consumes the
all-request budget plus applicable narrower budgets. Rejections are `429` JSON
with `Retry-After: 60` and `error_code: rate_limited`. Rejections on `/oauth/*`
and `/.well-known/*` carry the router's `Access-Control-Allow-Origin: *` and
expose `Retry-After`, so browser OAuth clients can read them. `reviews login`
waits out a 429 while polling for its token and keeps polling until the code
expires. Failed authentication also consumes the IP budget.

Defaults, per instance and per client bucket over 60 seconds:

| Budget | Requests | Scope |
| --- | ---: | --- |
| requests | 300 | Every endpoint request, including static assets |
| writes | 60 | POST, PUT, PATCH, DELETE outside `/live/*` |
| uploads | 20 | POST review and patchset routes |
| sockets | 60 | `/live/*` transport requests, including long polling |
| owners | 60 | Authenticated API writes, shared by all tokens/identities of the account |

These are initial operational choices, not load-test results. NATs, shared
proxies, browser tabs, and long polling share budgets; adjust after observing
legitimate usage. A request rejected by a later budget still consumes earlier
ones. Authenticated owner limiting happens after the token lookup, but before
parsing. It does not limit established LiveView write events.

All `/api/v1` write methods authenticate before parsing, with an API token or
a `reviews login` access token (whose DPoP proof is checked then). A successful
authentication is stored only in a server-owned `conn.private` entry and reused
by the router, so a proof is not checked twice; ordinary
`current_user`/`current_identity`/`current_principal` assigns do not bypass
verification. Poppy writes and `/mcp` keep their own authentication after
parsing; they get only the IP budgets and their body limits.
Bearer credentials remain opaque: seeded preview tokens can have a different
length or prefix from UI-minted tokens. Empty credentials and malformed
authorization headers are rejected without a token lookup.
Route classification decodes segments exactly as Phoenix.Router does.

Authenticated POST review and patchset bodies retain the **50,000,000-byte total
JSON request** allowance (including JSON wrapping and packet). `/mcp` requests
are limited to **4,000,000 bytes**. Other parsed bodies, including comments,
decisions, OAuth and device-login forms, are limited to **64,000 bytes**.
JSON and URL-encoded forms are supported. Multipart and other unsupported media
return `415`; the product has no multipart upload workflow. Oversized parsed
bodies return `413`; malformed JSON remains `400`. These parser errors use the
existing Phoenix error rendering rather than a new API error schema.

The reader counts actual bytes, regardless of Content-Length, in at most 64KB
requested chunks and rejects an oversized final chunk too. Bandit remains
responsible for HTTP framing: conflicting Transfer-Encoding/Content-Length,
truncated requests, and bytes beyond a declared Content-Length are not redefined
by this plug. Requests without a body according to HTTP framing have no body to
count. Successful bodies are still buffered and decoded in memory. The five
second read timeout is **per read**, not an overall upload deadline.

## Bounded local state

A supervised ETS owner maintains up to 16,384 hashed client buckets for each of
five fixed policies: at most 81,920 entries. Raw IPs, tokens, paths, and owner IDs
are not retained in the table. Lazy expiration resets a bucket 60 seconds after
its first accepted request. Hash collisions share a budget conservatively and
can reject unrelated clients. Counters use atomic compare-and-replace; after
eight races admission fails closed instead of spinning indefinitely. Missing
ETS state also fails closed during restart.

There is no per-request GenServer mailbox or unbounded client map. Counters are
local to a BEAM instance and reset on process restart/deployment. Two instances
can admit twice the per-instance allowance. This is not a distributed quota.

## Client-IP trust is a deployment prerequisite

By default **all forwarding headers are ignored** and the socket peer is used.
On Fly this can be a shared proxy peer, not an end user. Deploying these defaults
without validating attribution can throttle unrelated users together. This
branch deliberately does not silently enable Fly-header trust or change the
current IPv6 listener/network access.

Only peers explicitly listed as IP tuples in `:trusted_fly_proxy_peers` may
supply one syntactically valid `Fly-Client-IP`. Missing, duplicate, oversized, or
invalid headers fall back to the peer. Neither `X-Forwarded-For`, `Forwarded`,
nor `CF-Connecting-IP` is trusted. Never populate the allowlist from a request
header, allow all private addresses, or infer trust merely from `FLY_APP_NAME`.

[Fly documents](https://docs.fly.io/networking/request-headers) that
Fly-Client-IP is the client as seen by Fly Proxy: with another proxy in front,
it becomes that proxy's address. Its docs caution against spoofable XFF parsing.
Fly does not document stable socket-peer ranges as an authentication boundary.
An operator must verify the actual ingress boundary and direct-access exclusion
before configuring exact trusted peers; peer changes require revalidation. If
that cannot be established, do not enable header trust and do not present
peer-based budgets as per-user protection. Future Cloudflare support needs its
own verified trust chain and origin isolation; it is not included here.

## Configuration and limits

Application environment (no live configuration changed by this branch):

```elixir
config :reviews, ReviewsWeb.Plugs.RequestBudget,
  limits: [requests: 300, writes: 60, uploads: 20, sockets: 60, owners: 60],
  trusted_fly_proxy_peers: []

config :reviews, ReviewsWeb.Plugs.BodyBudget,
  upload_bytes: 50_000_000,
  mcp_bytes: 4_000_000,
  small_bytes: 64_000
```

Use positive integer limits; changing application environment changes subsequent
requests. Counters survive such changes until expiration. Avoid resetting them
as an incident response that inadvertently grants fresh budgets.

WebSocket establishment and long-poll HTTP requests pay admission. Once a socket
is established, events, LiveView remount/navigation, and snapshot work do not pass
through this gate. IP rotation, distributed sources, large valid uploads,
aggregate concurrency, slow uploads, and bandwidth/connection exhaustion remain
outside its guarantees. In particular, concurrent authenticated 50MB uploads can
still exhaust a 1GB machine; no aggregate or in-flight memory reservation is
implemented. Edge controls and established-event limits are separate follow-up
work requiring their own validation and authorization.
