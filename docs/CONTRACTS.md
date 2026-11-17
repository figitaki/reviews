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

Tokens are minted in the web UI at `/settings`. The raw token is shown once,
then only its SHA-256 hash is stored. There is **no** `POST /api/v1/tokens`
endpoint — tokens are user-initiated through the browser.

Missing/invalid token → `401` with body `{ "errors": { "detail": "Unauthorized" } }`.

### Permissions

The same rules hold on every surface (web, REST/CLI, Poppy) and are enforced
by `Reviews.Policy` in the domain layer:

| Action | Who may do it |
| --- | --- |
| Read a review | Anyone with the link. |
| Comment or reply | Any signed-in identity with the link. |
| Push a patchset | The review owner. |
| Resolve or reopen a thread | The review owner or the thread's author. |
| Decide a packet section | The review owner. Explicitly added reviewers will join once that feature exists. |

"Owner" and "author" mean the GitHub account: its human identity and all of
its agent identities share its permissions. Anyone else gets `403` with
`{ "errors": { "detail": "..." } }`, and nothing is written.

MCP (`docs/MCP.md`) still limits every tool to reviews the account owns,
which is stricter than these rules, until it moves to them.

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

Unknown slug or patchset number → `404`.

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

Sets or toggles the current token identity's decision for one packet section on
the latest patchset. `section_index` is zero-based.

Request body:

```json
{ "status": "approved" }
```

`status` must be one of `"approved"`, `"denied"`, or `"ignored"`.

Response `200`:

```json
{
  "review": "k7m2qz",
  "patchset_number": 2,
  "section_index": 0,
  "status": "approved"
}
```

Posting the same status again clears that identity's current decision. In that
case, `status` is `null`, meaning the section is pending.

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

Comments posted this way store `attribution` (a map of what was verified) and `identity_link_id`.
Thread payloads sent to the diff renderer include `comments[].attribution`, which is `null` for
comments made in the browser or through the CLI. It contains only `provider`, `verified_at`,
`client_id`, `client_domain`, `client_name_claimed`, `agent_id_claimed` (a boolean), `owner_username`,
`approved_at`, `link_revoked`, and `token_binding`: `"dpop"` when the comment's access token was
bound to the agent's DPoP key, `"bearer"` when it wasn't, and `null` for comments recorded before
Reviews kept the binding.

### Body size

`Plug.Parsers` is configured with `length: 50_000_000` so diffs up to ~50 MB
go through.

---

## MCP — `/mcp`

Streamable HTTP MCP endpoint for agents, off unless `MCP_ENABLED` is set (see
`docs/MCP.md` for tools, flags, and client setup). It authenticates with the
same `Authorization: Bearer <raw_token>` as the REST API and acts as the token's
identity. Tools read and write only reviews owned by the token's account;
foreign and unknown slugs get the same not-found result. Request bodies are
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

### Packet hunk row numbering

Packet `line_start` and `line_end` are one-based rows after the hunk's `@@` header. Context, added, deleted and empty rows each count once. A `\ No newline at end of file` marker does not count and stays with the preceding row when sliced. A final newline terminates the last row rather than adding a row. CLI validation, MCP coverage checks and the packet renderer use this convention.
