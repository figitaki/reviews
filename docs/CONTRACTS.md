# Reviews — interface contracts

This doc defines the wire contracts between the Phoenix server, the Rust CLI,
and the `DiffRenderer` LiveView hook. Anything not listed here is undefined
and can change.

---

## REST API — for the Rust CLI

All endpoints under `/api/v1/*` accept and return JSON.

### Auth

Every protected endpoint expects:

```
Authorization: Bearer <raw_token>
```

The token is one of:

- an access token from `reviews login` (the device authorization grant below),
  which acts as the identity the person chose at `/device` (their human
  identity or one of their agents) and lasts an hour; the CLI
  refreshes it with its rotating refresh token;
- an API token minted in the web UI at `/settings` (`reviews login --token`).
  The raw token is shown once, then only its SHA-256 hash is stored. There is
  **no** `POST /api/v1/tokens` endpoint.

Missing token → `401` with `WWW-Authenticate: Bearer`; invalid, expired, or
revoked token → `401` with `WWW-Authenticate: Bearer error="invalid_token"`.
Both have body `{ "errors": { "detail": "Unauthorized" } }`.

### Permissions

The same rules hold on every surface (web, REST/CLI, Poppy, MCP) and are
enforced by `Reviews.Policy` in the domain layer. Each surface authenticates
its caller as a `Reviews.Principal` (identity, account, scopes, attribution)
and passes it to the context functions:

| Action | Who may do it |
| --- | --- |
| Read a review | Anyone with the link. |
| Comment or reply | Any signed-in identity with the link. A Poppy grant also needs the `comments:write` scope. |
| Push a patchset | The review owner. |
| Resolve or reopen a thread | The review owner or the thread's author. |
| Decide a packet section | The review owner. Explicitly added reviewers will join once that feature exists. |
| Delete the review | The review owner. |

"Owner" and "author" mean the GitHub account: its human identity and all of
its agent identities share its permissions. Anyone else gets `403` with
`{ "errors": { "detail": "..." } }`, and nothing is written.

API tokens hold every scope. An OAuth grant (Poppy) holds only the scopes it
was approved for, so it can comment but cannot push, resolve, reopen or decide,
even for an identity that could do so with an API token. A refused comment is
`403`.

### Request budgets

Requests can return `429` JSON with `Retry-After: 60` and `error_code:
rate_limited` (the `Reviews.Errors` envelope). IP budgets apply before
DB/auth/body work; API writes also share an authenticated account budget across
tokens. Clients should wait before retrying, and should not retry writes blindly
when a response was lost. Counters are local to each instance and reset on restart.

Protected `/api/v1` writes authenticate before parsing (`401` takes precedence
over body errors), with an API token or a `reviews login` access token.
Review/patchset POSTs retain a 50,000,000-byte total JSON body limit; `/mcp`
requests are limited to 4,000,000 bytes; other parsed requests are limited to
64,000 bytes. Limits count bytes actually
read; oversized bodies receive `413`. Unsupported body media, including
multipart, receives `415`. CLI JSON and browser URL-encoded forms remain supported.
See [application request budgets](ABUSE_PROTECTION.md) for defaults, client-IP
handling on Fly, configuration, and limitations.

### `GET /api/v1/analytics/snapshot`

Dedicated aggregate-only authentication, disabled unless an expiring `rva_` credential
is configured. Normal account tokens are rejected; this credential cannot authorize
any other route. No parameters or request body are accepted. Responses are no-store.

The fixed version-2 payload has `version`, `source`, `collected_at`, `accounts`
(every account now), `mcp_clients` and `windows`. `mcp_clients` has one row per
recognized MCP connector (Claude, ChatGPT) and `Unrecognized`, each with `app`,
`connections` and `connected_accounts` for `/mcp` grants that are neither revoked
nor expired. Exactly two windows (7 and 30 days) each contain `days`, `start`, `end`,
`active_accounts`, `reviews`, `revisions`, `comments`, `decisions`, `signups`,
`mcp_connections` (`/mcp` grants approved in the window) and `mcp_active_accounts`
(accounts with an `/mcp` grant used in the window).
Active accounts count distinct identity owners, deduplicating human and agent
identities belonging to the same account. All counts are computed in PostgreSQL;
no identity IDs or content leave the database. See [aggregate export](AGGREGATE_EXPORT.md)
for boundaries, credential expiry/revocation and per-instance limits.

The credential authenticates as a `Reviews.Principal` with `via: :aggregate_export`
and no identity, account or scopes, so `Reviews.Policy` refuses it every write.
Errors carry the shared `error_code`: `unauthorized` (401), `invalid_request` (400,
query string or body), `method_not_allowed` (405), `insufficient_scope` (403, this
credential on any other route), `rate_limited` (429) and `unavailable` (503).

### `GET /api/v1/reviews`

Lists reviews. Powers `reviews list` and matches the `/reviews` web page.
Needs a bearer token.

The list has only reviews that the token's actor wrote or took part in.
Taking part means a published comment, a section decision, or a viewed hunk.
A review slug is the key to a link review, so the list never shows other
reviews, even public ones.

- A token for your human identity lists reviews for all of your identities
  (human and agents).
- A token for an agent identity lists only that agent's reviews.
- At `/mcp`, the `reviews_list` tool uses the same list. An OAuth connector
  grant (Claude, ChatGPT) lists the whole account, because it works for the
  person who approved it. `Reviews.Policy.list_viewer/1` holds these rules.

Query params (all optional):

| Param    | Values                           | Default | Meaning |
| -------- | -------------------------------- | ------- | ------- |
| `role`   | `all`, `authored`, `involved`    | `all`   | `authored`: one of your identities wrote it. `involved`: someone else wrote it and you took part. |
| `status` | `all`, `open`, `updated`         | `all`   | `open`: has open threads. `updated`: someone else wrote it and it has a patchset newer than your last action on it. |
| `author` | identity handle, `@` is optional | none    | Author handle. Case does not matter. |
| `q`      | text                             | none    | Finds the text in the title or slug. Case does not matter. |
| `limit`  | 1 to 100                         | 25      | Page size. |
| `offset` | 0 or more                        | 0       | Rows to skip. |

Rows are sorted by `updated_at`, newest first. `updated_at` is the later of
the review's last change and its newest patchset push.

Response `200`:

```json
{
  "reviews": [
    {
      "slug": "k7m2qz",
      "title": "Make user lookup faster",
      "url": "http://localhost:4000/r/k7m2qz",
      "author": {
        "id": 3,
        "kind": "human",
        "handle": "conner",
        "username": "conner",
        "display_name": "conner",
        "avatar_url": null
      },
      "role": "involved",
      "patchset_count": 2,
      "latest_patchset_number": 2,
      "last_pushed_at": "2026-10-09T15:04:00Z",
      "updated_at": "2026-10-09T15:04:00Z",
      "thread_count": 3,
      "open_thread_count": 1,
      "last_activity_at": "2026-10-08T11:20:00Z",
      "has_new_patchset": true,
      "created_at": "2026-10-07T09:00:00Z"
    }
  ],
  "limit": 25,
  "offset": 0,
  "next_offset": null
}
```

`next_offset` is the `offset` for the next page, or `null` on the last page.
`last_activity_at` is your last comment, decision, or viewed hunk on the
review, or `null`. `has_new_patchset` is `true` when a patchset is newer than
`last_activity_at`. It is always `false` on reviews you wrote, since only the
author's account can push patchsets.

A bad param value gives `400` with one message per param:

```json
{ "errors": { "role": "must be one of: all, authored, involved" } }
```

### `POST /api/v1/reviews`

Creates a new review and its first patchset.

Request body:

```json
{
  "title": "Make the user lookup faster",
  "description": "Optional longer markdown body.",
  "base_sha": "deadbeef1234",
  "branch_name": "carey/user-lookup-perf",
  "raw_diff": "diff --git a/lib/foo.ex b/lib/foo.ex\n...",
  "packet": { "...": "optional review packet JSON" }
}
```

Response `201`:

```json
{
  "id": 42,
  "slug": "k7m2qz",
  "url": "http://localhost:4000/r/k7m2qz",
  "patchset_number": 1
}
```

Validation errors → `422` with `{ "errors": { "field": ["message", ...] } }`.
`title`, `base_sha` and `branch_name` are at most 255 characters, as are file
paths in `raw_diff`.

### `POST /api/v1/reviews/:slug/patchsets`

Appends a new patchset to an existing review. The slug comes from the
previous response.

Request body:

```json
{
  "base_sha": "cafef00d",
  "branch_name": "carey/user-lookup-perf",
  "raw_diff": "diff --git a/lib/foo.ex ...",
  "packet": { "...": "optional review packet JSON" }
}
```

Response `201`:

```json
{ "patchset_number": 2, "url": "http://localhost:4000/r/k7m2qz" }
```

Unknown slug → `404`. A token whose account does not own the review → `403`.

Both create endpoints accept an optional `code_snapshot_id` (a snapshot UUID
from `POST /api/v1/code-snapshots` that has been completed). When present, the
201 response carries a `code_snapshot` key: `{"id": "<uuid>", "status": "claimed"}`
on success, or `{"status": "skipped", "code": "<error code>"}` when the claim
failed under the `optional` storage policy (the push still succeeds diff-only).
Under the `required` policy a failed claim aborts the whole request with the
error-code envelope below and creates nothing.

### `GET /api/v1/reviews/:slug`

Public (no token). Returns a JSON snapshot of the review: `slug`, `title`,
`description`, `url`, `patchsets` (metadata and stats for each patchset),
`selected_patchset` (with `packet` and per-file `raw_diff`), and the published
`threads`. The latest patchset is selected by default. Use `?patchset=N` to
select another one.

Threads are projected onto the selected patchset, not the latest one. Threads
originating in later patchsets are omitted. `line_hint` is null when the code
cannot be located unambiguously in the selected diff; the thread and comments
remain visible and its open/resolved status is unchanged.

Unknown slug or patchset number → `404`. A deleted review's slug → `410`
with `error_code` `review_deleted`.

### `GET /api/v1/reviews/:slug/deletion`

Owner only. Says what deleting the review would remove, so a client can warn
before it deletes. Powers the confirmation of `reviews delete`. Response
`200`:

```json
{
  "slug": "k7m2qz",
  "title": "Make the user lookup faster",
  "patchsets": 2,
  "threads": 3,
  "comments": 7,
  "other_comments": 4,
  "other_authors": ["dana", "helper"]
}
```

`other_comments` counts comments by identities of other accounts (people and
their agents); the owner's own agent identities are not "others".
`other_authors` lists those identities' handles.

### `DELETE /api/v1/reviews/:slug`

Owner only. Permanently deletes the review and everything it owns: patchsets
(with their files and packets), threads and every comment on them, including
other people's, section decisions, and viewed-hunk state. It cannot be undone.
The server keeps only the slug and the deletion time, so the link can say the
review was deleted. The request has no body; clients confirm before sending
it (the CLI and the review page ask the owner to type the slug). Response
`200`:

```json
{ "slug": "k7m2qz", "deleted": true }
```

Errors: no token → `401`; a token whose account does not own the review →
`403` `forbidden` ("Only the review owner can delete it."); unknown slug →
`404` `review_not_found`; already deleted → `410` `review_deleted`.

After a deletion, every `/api/v1/reviews/:slug...` endpoint that looks the
review up by slug (show, comments, patchsets, thread status, section
decisions) answers `410` `review_deleted` instead of `404`; the bounded
`files`/`threads`/`comments` pages still answer `404`. The web page
`/r/:slug` answers `410` with a "This review was deleted" page.

### `POST /api/v1/reviews/:slug/comments`

Publishes one comment right away as the token identity. Request body:

```json
{
  "file_path": "lib/foo.ex",
  "side": "new",
  "body": "Should this be `String.to_existing_atom`?",
  "thread_anchor": { "granularity": "line", "line_number_hint": 42, "line_text": "..." }
}
```

`side` defaults to `"new"`. Response `201` has `thread_id`, `comment_id`,
`file_path`, `side`, `anchor`, and `url`. An empty body, a bad anchor, or a
`file_path` over 255 characters → `422` with `{ "errors": { "detail": "..." } }`.
Unknown slug → `404`.

### `GET /api/v1/comments/wait`

Long poll for new comments and replies on one or more reviews, for
`reviews wait`. Needs a bearer token; any signed-in identity with the links
may wait, as for commenting. Query parameters:

- `reviews`: 1–20 review slugs, separated by commas. Required.
- `since`: a comment id. Comments on these reviews with a higher id return at
  once. Without it, or with one above the reviews' newest comment, the call
  waits for comments published after it starts. Comment ids are one sequence
  across reviews, so one cursor covers them all.
- `timeout`: seconds to hold the call when nothing is new. Default 25, 0–30.
- `limit`: most comments returned. Default 50, 1–50.

Response `200`:

```json
{
  "comments": [
    { "review": "Q4bwuxuZ", "thread_id": 7, "comment_id": 41, "author": "dana",
      "file_path": "lib/foo.ex", "side": "new", "line": 42, "body": "...",
      "truncated": false }
  ],
  "cursor": 41,
  "more": false
}
```

Comments are oldest first and leave out the caller's own (by the token's
identity). `author` is the identity's handle; `body` is capped at 8000 bytes,
and `truncated` says whether it was cut. `cursor` is the `since` for the next
call: the last comment's id when `limit` comments were returned (`more` is then
true), otherwise the reviews' newest comment id, which can be above the last
comment returned when the newest are the caller's own.

The server wakes on the reviews' `{:thread_published, thread}` broadcasts rather
than polling the database, and reads again only when the broadcast's thread
belongs to one of the reviews and carries a comment above the cursor by someone
else, so other broadcasts cost a waiter no query. It returns early with no
comments if a review is deleted. One identity may hold 5 waits at once and a
server node 500; more → `429` with `error_code: rate_limited`. A cursor never skips a comment: each comment insert takes a per-review
advisory lock until it commits, and the read takes the shared form of that lock
for each review, so no lower id can commit after a read returns a higher one.
A bad parameter, or a slug outside `[A-Za-z0-9_-]{1,64}`, → `400` with
`error_code: invalid_request`; an unknown slug →
`404` and a deleted review → `410`, with the slug in `error_detail`.

### `PATCH /api/v1/reviews/:slug/threads/:thread_id`

Resolves or reopens a thread as the token identity. Powers `reviews resolve`
and `reviews reopen`. Request body:

```json
{ "status": "resolved" }
```

`status` must be `"open"` or `"resolved"` (otherwise `422`). Response `200`
has `id`, `status`, `resolved_by` (an identity, or `null`), and `resolved_at`.
Setting the status a thread already has changes nothing and keeps the
original resolver. Unknown slug, or a thread that is not in this review →
`404`. A token whose account is neither the review owner nor the thread's
author → `403`, even when the status would not change.

### `GET /api/v1/capabilities`

Unauthenticated feature discovery for the CLI. Older servers have no such
route; treat a `404` as code storage disabled.

```json
{
  "code_storage": {
    "enabled": false,
    "required": false,
    "supported_object_formats": ["sha1"],
    "max_upload_bytes": 536870912,
    "max_upload_bytes_enforced": false
  },
  "lsp": { "enabled": false, "languages": [] }
}
```

`max_upload_bytes` is an advisory budget, not a rejection threshold.
`max_upload_bytes_enforced: false` means neither the CLI nor server enforces
that budget. The first push can transfer all history reachable from the base
commit; operators must not rely on this field to bound storage or transfer costs.

### `POST /api/v1/code-snapshots`

Reserves a code snapshot for upload. Requires a token. Returns `404` with
code `code_storage_disabled` when storage is off.

Request body:

```json
{
  "review_slug": "k7m2qz",
  "object_format": "sha1",
  "base_oid": "<full 40/64-hex object id>",
  "head_oid": "<full 40/64-hex object id>",
  "head_kind": "commit"
}
```

`review_slug` is omitted for a new review. When it is present, the caller
must be allowed to add patchsets to that review; otherwise the server returns
`403` with code `snapshot_not_authorized` and reserves nothing. `head_kind` is
one of `commit`, `index_snapshot`, `worktree_snapshot`.

Response `201`:

```json
{
  "id": "<snapshot uuid>",
  "repository_id": "<repository uuid>",
  "expires_at": "2026-09-01T18:30:00Z",
  "upload": {
    "remote_url": "https://<org>.code.storage/reviews/<repository uuid>.git",
    "token": "<short-lived ES256 JWT, scoped to the two refs below>",
    "expires_at": "2026-09-01T18:15:00Z"
  },
  "refs": {
    "base": "refs/heads/snapshots/<snapshot uuid>/base",
    "head": "refs/heads/snapshots/<snapshot uuid>/head"
  }
}
```

Push both refs in one atomic `git push`, sending the token as HTTP basic auth
(user `t`) via header injection — never embed it in the URL, git config, or
logs.

### `POST /api/v1/code-snapshots/:id/complete`

Asks the server to verify the uploaded refs against the reserved object ids.
Unclaimed reservations return `upload_expired` (410) at or after their deadline,
even before the sweeper runs. Completion rechecks state and deadline after
provider verification; a late result cannot revive an expired snapshot or
overwrite a completed/claimed one. Claiming also checks the deadline under
the snapshot lock. Claimed snapshots remain idempotently completable. Response `200`:

```json
{ "id": "<snapshot uuid>", "status": "ready", "base_oid": "...", "head_oid": "..." }
```

Code-storage errors use the shared error envelope (`Reviews.Errors`):

```json
{ "errors": { "detail": "human message" }, "error_code": "ref_mismatch", "error_detail": "human message" }
```

Codes: `code_storage_disabled` (404), `snapshot_not_authorized` (403),
`upload_expired` (410), `invalid_snapshot`, `unsupported_object_format`,
`ref_mismatch`, `snapshot_not_ready`, `repository_too_large` (422), and
`code_storage_unavailable` (502) when the provider cannot be reached.

### `GET /api/v1/me`

Powers `reviews whoami`. Response `200`:

```json
{
  "username": "careyjanecka",
  "email": "carey@example.com",
  "identity": {
    "id": 7,
    "kind": "agent",
    "handle": "codex",
    "username": "codex",
    "display_name": "Codex",
    "avatar_url": null
  }
}
```

`username` and `email` describe the owning GitHub account. `email` is `null`
when the account has no public email. `identity`
describes the actor attached to the bearer token; comments, review pushes, and
packet-section decisions authored through the token use that identity.

### `POST /api/v1/reviews/:slug/sections/:section_index/decision`

Sets the token account's decision for one packet section on the latest
patchset. `section_index` is zero-based. Decisions belong to the account (a
person and their agent identities share one decision per section); the stored
decision records which identity set it.

Request body:

```json
{ "status": "approved" }
```

`status` must be one of `"approved"`, `"denied"`, `"ignored"`, or `"pending"`
(undecided, overriding a decision carried from an earlier patchset).

Response `200`:

```json
{
  "review": "k7m2qz",
  "patchset_number": 2,
  "section_index": 0,
  "status": "approved"
}
```

The status is set, not toggled: posting the status the section already has
changes nothing, so a retried request is safe. Before this change, posting the
same status again cleared the decision and returned `"status": null`; the CLI
still accepts that reply from older servers. Writes for one patchset are
serialized, so concurrent requests never act on stale state.

Only the review owner's identities may decide sections; any other token →
`403` with `{ "errors": { "detail": "Only the review owner can decide sections" } }`.

### OAuth issuer (`/oauth`)

APIs other than `/api/v1` accept OAuth access tokens from the Reviews issuer
(`Reviews.OAuth`). Each such API is a protected resource configured in
`config :reviews, Reviews.OAuth, resources: [...]`; none is configured on
`main` yet.

- `GET /.well-known/oauth-authorization-server`: RFC 8414 metadata.
- `GET /.well-known/oauth-protected-resource[/<path>]`: RFC 9728 metadata for
  the enabled resource at `<path>`, 404 otherwise.
- `GET|POST /oauth/authorize`: authorization code with PKCE (`S256` only) and
  an optional RFC 8707 `resource`. The owner signs in with GitHub and picks
  one of their agent identities; the human identity is never offered or
  accepted. Every redirect back carries `iss` (RFC 9207).
- `POST /oauth/token` (`application/x-www-form-urlencoded`):
  `authorization_code` and `refresh_token`. Clients authenticate with
  `private_key_jwt` (ES256, PS384, RS256; `aud` is the issuer) or, for a
  resource that takes public clients, `none`. Rotating refresh tokens revoke
  the grant when a replaced one is presented again.
- `POST /oauth/device_authorization` (RFC 8628, form body): `client_id`,
  optional `scope` and `resource`. Returns `device_code`, `user_code`
  (`XXXX-XXXX`, consonants only), `verification_uri` (`/device`),
  `verification_uri_complete`, `expires_in` (600), and `interval` (5). Only the
  pre-registered public client `reviews-cli` uses it, for the CLI API
  (resource `<issuer>/api/v1`, scope `cli`); no other client may get that
  resource's tokens. The CLI then polls `POST /oauth/token` with
  `grant_type=urn:ietf:params:oauth:grant-type:device_code`, and gets
  `authorization_pending`, `slow_down` (polled faster than the interval; the
  interval grows by 5 seconds for that code), `access_denied`,
  `expired_token`, or the tokens. A device code is redeemed once; presenting
  it again revokes the sign-in.
- `GET|POST /device`, `POST /device/decide`: the signed-in person enters the
  code, checks it, picks an identity (`identity_id`: their human identity,
  the default, or one of their agents; any other ID is refused and leaves the
  code pending), and allows or denies. `/api/v1` is the only resource that
  accepts a human subject. A link with `?user_code=` only
  fills the code; approval is always a POST. Ten wrong codes in 15 minutes
  lock the person out of the page for the rest of the window.
- `POST /oauth/revoke`: RFC 7009.
- `POST /oauth/register`: RFC 7591 JSON, public clients only, 201 with
  `client_id`; 404 while no resource takes public clients.

A `client_id` is either an HTTPS URL naming a client ID metadata document or
an `rvc_` ID from registration. Discovery and the JSON endpoints send
`Access-Control-Allow-Origin: *`. Tokens of one resource are refused by every
other.

### Poppy API (`/api/poppy/v1`)

Personal Agents use Poppy 1.0 instead of bearer API tokens. Each request carries `Poppy-Session` and
`Poppy-Version: 1.0`. A signed-in request also carries an access token from Direct Sign-In
(`/oauth/authorize`, `/oauth/token`). `GET /api/poppy/v1/reviews/:slug` returns the same body as
`GET /api/v1/reviews/:slug`. `POST /api/poppy/v1/reviews/:slug/comments` takes the same body and
response as the CLI endpoint and needs the `comments:write` scope. Any linked agent may comment on any
review it has the link to; the permission rules above apply. Session errors are HTTP 400 with
`{"error": "invalid_session" | "session_ended" | "version_unsupported"}`. Token errors are 401 or 403
in `WWW-Authenticate`, with a `Bearer` and a `DPoP` challenge. A token issued with
`token_type: "DPoP"` is sent as `Authorization: DPoP <token>` with a `DPoP` proof (RFC 9449). A
missing or invalid proof is 401 `invalid_dpop_proof`. Bearer API tokens are refused on these routes, and Poppy tokens are refused
on `/api/v1`. See `docs/POPPY.md`.

Comments posted this way store `attribution` (a map of what was verified) and `oauth_grant_id`, the
grant they were posted under (`attribution["link_id"]` holds the same ID).
Thread payloads sent to the diff renderer include `comments[].attribution`, which is `null` for
comments made in the browser or through the CLI. It contains only `provider`, `verified_at`,
`client_id`, `client_domain`, `client_name_claimed`, `agent_id_claimed` (a boolean), `owner_username`,
`approved_at`, `link_revoked`, `token_binding`, `delegation_signed_by`, `turnkey_organization_id`, and
`turnkey_agent`. `token_binding` is `"dpop"` when the comment's access token was bound to the agent's
DPoP key, `"bearer"` when it wasn't, and `null` for comments recorded before Reviews kept the binding.
`delegation_signed_by` is `"turnkey"` or `null`. It and the two Turnkey fields are set only for agents
hosted by Turnkey whose delegation verified as Turnkey's `poppy-delegation/v1` profile (see
"Turnkey-held identity keys" in `docs/POPPY.md`).

### Body size

`Plug.Parsers` is configured with `length: 50_000_000` so diffs up to ~50 MB
go through.

---

## MCP — `/mcp`

Streamable HTTP MCP endpoint for agents, off unless `MCP_ENABLED` is set (see
`docs/MCP.md` for tools, flags, and client setup). It authenticates with the
same `Authorization: Bearer <raw_token>` as the REST API, or with an OAuth
access token issued for the resource `https://HOST/mcp`, and acts as the
token's identity. A 401 or 403 carries `WWW-Authenticate: Bearer
resource_metadata="https://HOST/.well-known/oauth-protected-resource/mcp", ...`.
`/mcp` is a resource of the OAuth issuer above (`Reviews.MCPAuth`): its
metadata is served only while MCP is on, it takes public clients (`none`) and
`private_key_jwt`, and its refresh tokens rotate. Its scopes are
`reviews:read`, `reviews:write`, `comments:write`, and `threads:write`; an
OAuth token's writes are limited to them. Tools find reviews by link and
follow the permission rules above; `search` lists only the account's own
reviews; unknown slugs get a not-found result. Request bodies are
capped at 4 MB before decoding; the REST limit above does not apply.

---

## LiveView `DiffRenderer` hook

The hook is registered in `assets/js/app.js` under the name `DiffRenderer`
and lives in `assets/js/hooks/diff_renderer.js`. It mounts one vanilla
`@pierre/diffs` renderer per element. Each element is rendered by
`ReviewsWeb.ReviewLive.PacketComponents` with `phx-hook="DiffRenderer"`, a
unique DOM id, and `phx-update="ignore"` (the hook owns its DOM tree).
`assets/js/schemas.js` holds the zod schemas that check every payload below.

### `data-*` props on mount

| Attribute              | Type     | Description                                              |
| ---------------------- | -------- | -------------------------------------------------------- |
| `data-file-id`         | string   | DOM-unique id for this file/hunk mount.                  |
| `data-file-path`       | string   | The file's path in the diff (`lib/foo.ex`).              |
| `data-file-status`     | string   | `"added"`, `"modified"`, `"deleted"`, or `"renamed"`.    |
| `data-patchset-number` | string   | The patchset number this file belongs to.                |
| `data-side`            | string   | Always `"new"` today.                                    |
| `data-raw-diff`        | string   | Raw unified diff for this file or hunk only.             |
| `data-full-diff`       | optional string | Whole-file patch for added/deleted Markdown files, so sliced packet hunks can preview the complete document. Source and thread counts still use `data-raw-diff`. |
| `data-threads`         | string (JSON) | Published threads in this file. Shape: the `Thread` schema in `schemas.js`. Each thread's `can_update_status` says whether the viewer may resolve or reopen it; the renderer shows those buttons only when it is `true`. |
| `data-signed-in`       | string   | `"true"` or `"false"`. Signed-out viewers get a sign-in prompt instead of a composer. |
| `data-diff-style`      | string   | `"split"` or `"unified"`.                                |

Markdown files default to Preview, including files with discussions, unless the
excerpt is ambiguous or exceeds 1,500 rendered lines / 200 KiB. Explicit mode
choices are stored locally per review URL and file path, across revisions.
Opening a discussion (a discussion button or `open_review_thread`) switches that
file to Source for the current page without changing the stored choice.
Preview DOM is cached for the lifetime of its renderer, independently of thread,
viewed, theme and layout updates. Large files use Source's virtualized renderer.
Added/deleted files preview their complete document with a single panel. Other
files remain excerpts: fences with omitted context, headerless table fragments,
and leading indented continuations fall back to Source with an explanation.
Repository-relative links are non-navigating text in Preview because no repository
base URL is available; Source retains their exact destinations. External links
open separately without sharing the review URL.

### Events the hook pushes to LiveView

`this.pushEvent("create_comment", payload)` publishes a comment right away:

```json
{
  "thread_anchor": {
    "granularity": "line",
    "line_text": "  const userId = req.user.id;",
    "context_before": [],
    "context_after": [],
    "line_number_hint": 42
  },
  "body": "Should this be `String.to_existing_atom`?",
  "file_path": "lib/foo.ex",
  "line_text": "  const userId = req.user.id;",
  "side": "new",
  "thread_id": null
}
```

Set `thread_id` to reply to an existing thread.

### Events LiveView pushes to the hook

Events are scoped by file path, so a change in one file does not re-render
every mounted renderer.

| Event                             | Payload                      | Meaning                                         |
| --------------------------------- | ---------------------------- | ----------------------------------------------- |
| `threads_updated:<file_path>`     | `{ threads: [...] }`         | Published threads in this file changed. Re-render with the new list. |
| `open_review_thread` | `{ thread_id, file_path, hunk_id? }` | Open and focus a discussion. When `hunk_id` is present, only that Guide renderer handles the event. |
| `diff_style_updated:<file_path>`  | `{ style: "split" \| "unified" }` | The viewer switched the diff layout.     |

Activity links use `/r/:slug?patchset=N&thread=ID`. They select and expand the
first Guide hunk containing the thread's anchored line on its diff side. If no
Guide hunk covers it, navigation falls back to `/r/:slug/changes` with the same
query. Outdated discussions link to their originating revision.

A thread card's copy-link buttons write the same link for the current page,
keeping its view and `patchset`. A comment link adds `&comment=ID`; the diff
renderer then scrolls to that comment instead of the thread header and
highlights it briefly. A thread link highlights the whole card.

The patchset-pushed banner is rendered by LiveView itself (no hook event).
When LiveView receives `{:patchset_pushed, n}` on the `"review:<slug>"`
PubSub topic, it assigns a banner message that the HEEx template displays.

### Thread anchor shape (jsonb in DB, JSON over the wire)

```json
{
  "granularity": "line",
  "line_text": "  const userId = req.user.id;",
  "context_before": ["..."],
  "context_after": ["..."],
  "line_number_hint": 42
}
```

`granularity: "token_range"` adds `selection_text` and `selection_offset`
(a zero-based UTF-16 code-unit offset, matching browser strings).

`Reviews.Anchoring.relocate(thread, origin_patchset, target_patchset)` matches
exact whole-line content on the thread's `file_path` and `side`. Duplicate
lines require unique exact `context_before`/`context_after` matches. Token
ranges additionally require the selected text at the stored offset; legacy
ranges without offsets require a unique substring on that line. Changed whole
lines, missing files, ambiguous matches, and lines outside the target diff's
known changed/context lines return `{:error, :outdated}`. No fuzzy match, line
number fallback, cross-file/side match, or unseen-file reconstruction is used.

`ReviewView.snapshot/3` leaves persisted threads untouched and exposes projected
thread maps in `published_threads`, including `original_anchor`,
`originating_patchset_id`, `originating_patchset_number`, and `anchor_status`
(`"current"` or `"outdated"`). `anchor` is the selected-patchset anchor, or nil
when outdated. Resolution status, actor, timestamps and comments are preserved.
On the originating patchset the original anchor is used unchanged. Future-origin
threads are omitted. `ReviewView.thread_payloads_for_file/2` excludes outdated
threads so renderers cannot place them on stale lines. Activity navigation must
use the originating patchset number and original anchor for outdated threads.

`Threads.publish_comment/3` accepts optional `originating_patchset_id` (string
or atom key) for new threads. It must identify a patchset of this review or the
call returns `{:error, :patchset_not_found}` without writing. Omission defaults
to the latest patchset. Callers creating comments on an older selected revision
must pass its ID server-side. Replies keep their original thread's origin.

### Comment revisions and replies

REST and Poppy comment creation accept an optional positive integer `revision` (the review-local revision number). The CLI exposes it as `reviews comment SLUG FILE:LINE --revision N`. `originating_patchset_id` is also accepted for clients that have the exact database ID; it must belong to this review. Do not send both selectors. Invalid or foreign targets return 422 without writing.

An omitted target selects the latest committed revision when the request resolves its anchor. This is not an expected-latest precondition. Once selected, the immutable revision ID is used through insertion, even if another revision is appended concurrently. An exact older revision is never silently retargeted.

New threads require a line present on the selected file and side of that revision's diff. The server captures line text and neighboring context. Token anchors must select text on that line; offsets use UTF-16 code units. Without an offset, the selected substring must occur exactly once. Invalid paths, lines or selections return 422.

Replies require only `{thread_id, body}` and preserve the thread's file, side, anchor and originating revision. Extra location/revision fields do not redirect a reply. A missing or foreign thread returns 404. Poppy attribution is retained. The CLI posts replies directly without downloading the review snapshot.

### Stable application error codes

REST and Poppy application errors add `error_code` and `error_detail` alongside the existing `errors` fields. Poppy authentication retains the protocol-required string `error` and challenge headers and adds the same code/detail fields. Clients should branch on the code, not the prose; field-validation messages remain in `errors`. This is additive rather than replacing the published v1 envelope.

Codes include `review_not_found`, `review_deleted` (410), `thread_not_found`, `patchset_not_found`, `section_not_found`, `forbidden`, `unauthorized`, `invalid_request`, `invalid_status`, `invalid_section_index`, `invalid_anchor`, `invalid_side`, `invalid_file_path`, `empty_body`, `unknown_granularity`, `validation_failed`, `write_failed`, `method_not_allowed`, `rate_limited` and `unavailable`. Poppy authentication uses its existing protocol codes (`invalid_session`, `session_ended`, `version_unsupported`, `invalid_token`, `invalid_dpop_proof`, `insufficient_scope`). Both thread and section-decision requests with missing status return 422. Malformed section indices retain their existing 400 response.

`Reviews.Errors` is the one list of codes, with one HTTP status and one default detail each. REST, Poppy and MCP (`structuredContent.error.code`) all map domain reasons through it, so the same failure has the same code on every surface; an unknown reason is sent as `write_failed`, never as its internal name. It adds `invalid_pagination` (bad cursor, `limit` or `max_bytes` on paged reads) and `invalid_packet` (a packet that fails validation; field messages stay in `errors.packet`).

MCP tool errors retain `isError` and human-readable content and add `structuredContent.error.{code,detail}`. Unclassified tool parameter errors use `invalid_request`; known missing resources, permissions, invalid anchors and failed writes have specific codes. Transport/framework errors remain owned by FastestMCP. The CLI consumes stable codes when available and falls back to existing HTTP-status hints for older servers. The invalid-anchor response is checked by both Elixir and Rust against `test/vectors/api/invalid-anchor.json`.

### Packet hunk row numbering

Packet `line_start` and `line_end` are one-based rows after the hunk's `@@` header. Context, added, deleted and empty rows each count once. A `\ No newline at end of file` marker does not count and stays with the preceding row when sliced. A final newline terminates the last row rather than adding a row. CLI validation, MCP coverage checks and the packet renderer use this convention.

### Packet validation on upload

Review creation and revision uploads validate a supplied packet in the shared patchset changeset. REST and MCP reject malformed shapes, unknown hunk references, invalid slices, omitted changes and repeated changed rows before committing. REST returns 422 with `errors.packet`; MCP returns a tool error. Omitted/null packets remain supported. Existing stored packets remain readable; this does not rewrite historical content.

`Reviews.PacketValidation.check/2` returns `:ok` or coded problems: `invalid_packet.shape`, `invalid_packet.unknown_hunk`, `invalid_packet.invalid_slice`, `invalid_packet.uncovered_line`, and `invalid_packet.repeated_line`. Hunk indices and slice bounds must be JSON integers, not strings; paths and titles must not be blank. The CLI keeps its local preflight checks.

### Public comment and thread metadata

REST and Poppy snapshots retain `file_path`, `line_hint` and existing identity fields. Threads also expose `path`, `line`, `line_text`, `anchor_status` (`current` or `outdated`) and `originating_revision`; an outdated anchor has no projected line. Comments include stable `id` and public `attribution` (null for ordinary comments). Attribution uses the same allowlist as the web view: pairwise subjects, sessions and key thumbprints are never returned. `agent_id_claimed` indicates presence, not the private claimed identifier.

MCP uses the same comment and identity serializers with its existing compact identity projection (`id`, `kind`, `handle`, `display_name`) and byte budgets. Public attribution is present for externally verified comments; absent ordinary attribution remains omitted in compact responses. Snapshot bodies from REST and Poppy are identical after authentication.

Paged/compact comment readers cap each public attribution and identity string at 512 UTF-8 bytes and set `metadata_truncated: true` if any field was shortened. Full snapshots retain the complete public metadata. This prevents oversized client metadata from blocking comment-body pagination.
### Bounded read endpoints

Both `/api/v1` and `/api/poppy/v1` provide `GET /reviews/:slug/files`, `/reviews/:slug/threads`, and `/reviews/:slug/threads/:thread_id/comments`. REST keeps public link-based read access; Poppy requires a verified Session and Poppy-Version as for the snapshot. The existing snapshot endpoint remains unchanged for CLI compatibility.

Pages return `slug`, `revision`, `next_cursor` (null at the end), and `files`, `threads` or `comments`. `limit` defaults to 25 and is 1–100. `max_bytes` defaults to 40000 and is 2000–120000; it bounds the JSON response body. File pages contain metadata and byte counts, never raw diffs. Thread pages contain projected anchor state and comment counts, never embedded comment bodies; `line_text` is capped at 500 bytes. Threads accept optional `status` (`open` or `resolved`) and `path` filters.

REST and Poppy use `Reviews.Paging` for cursor encoding and page limits. Pass opaque `next_cursor` unchanged with the same endpoint, review, revision, thread and filters; a cursor from another query is rejected. Page sizes may change between calls. REST and Poppy share a cursor scope; MCP uses a distinct scope because comment position semantics differ. Cursors are query-tagged positions, not authorization tokens; every request retains its normal access checks. Legacy untagged cursors are rejected; restart from the first page. Revision numbers must be integers from 1 through 2147483647, independently of page-size limits. The first request may omit `revision` to select latest; all continuation requests must include the returned revision. Revision selection pins diff projection, not a database snapshot: new comments and thread status changes can appear while paging. Comments carry stable IDs, `offset` (UTF-8 byte offset), `body` (one chunk), and `complete`; concatenate chunks for the same comment until complete. A page can stop before `limit` to fit its byte budget. If metadata alone cannot fit, retry with a larger budget. Invalid limits, cursors, offsets or missing continuation revision return 422 with `error_code: invalid_pagination`; missing/foreign/future threads and missing revisions return 404 with `error_code: resource_not_found`. Both retain `errors.detail` and expose the same prose as `error_detail`.

These endpoints use bounded domain page queries rather than loading the full review snapshot. Poppy OpenAPI documents their parameters and response envelopes, which are checked against actual endpoint results.

### Packet hunk fragments

Guide URLs accept packet hunk fragments, including rendered `-summary` and
`-diff` IDs and packet row IDs (`#packet-section-N-row-M`). Rows grouped into
one card resolve to that card. Include `?patchset=N` to link to a historical
revision; targets are always resolved against the selected revision, never a
different patchset. Unknown targets leave the current section unchanged.

The `PacketFragments` hook sends `reveal_packet_fragment` with `{id}` after
connection, hash changes, repeated same-fragment clicks, and revision changes.
The server validates the ID against rendered packet units, reveals the section,
expands its card, and replies with `{id: canonical_dom_id}` (or `{id: null}` for
an unknown target). The client focuses and scrolls after the patch is applied.
Native anchor navigation owns URL/history; returning to an empty fragment sends
`restore_packet_location` with the URL's `thread` value. It restores that
discussion when present, or Overview otherwise. Modified clicks, external links,
and different URLs retain native browser behavior. This does not enable packet fragments on the raw
`/changes` view or make hunk IDs stable across changed packet contents.
