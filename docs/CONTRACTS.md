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

Unknown slug → `404`.

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
`file_path`, `side`, `anchor`, and `url`. An empty body or a bad anchor →
`422`. Unknown slug → `404`.

### `GET /api/v1/capabilities`

Unauthenticated feature discovery for the CLI. Older servers have no such
route; treat a `404` as code storage disabled.

```json
{
  "code_storage": {
    "enabled": false,
    "required": false,
    "supported_object_formats": ["sha1"],
    "max_upload_bytes": 536870912
  },
  "lsp": { "enabled": false, "languages": [] }
}
```

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

`review_slug` is omitted for a new review. `head_kind` is one of `commit`,
`index_snapshot`, `worktree_snapshot`.

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
Idempotent. Response `200`:

```json
{ "id": "<snapshot uuid>", "status": "ready", "base_oid": "...", "head_oid": "..." }
```

Code-storage errors use a stable machine-readable envelope:

```json
{ "errors": { "detail": "human message", "code": "ref_mismatch" } }
```

Codes: `code_storage_disabled` (404), `snapshot_not_authorized` (403),
`upload_expired` (410), `unsupported_object_format`, `ref_mismatch`,
`snapshot_not_ready`, `repository_too_large` (422).

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

`username` and `email` describe the owning GitHub account. `identity`
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

### Body size

`Plug.Parsers` is configured with `length: 50_000_000` so diffs up to ~50 MB
go through.

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
| `data-threads`         | string (JSON) | Published threads in this file. Shape: the `Thread` schema in `schemas.js`. |
| `data-signed-in`       | string   | `"true"` or `"false"`. Signed-out viewers get a sign-in prompt instead of a composer. |
| `data-diff-style`      | string   | `"split"` or `"unified"`.                                |

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
| `diff_style_updated:<file_path>`  | `{ style: "split" \| "unified" }` | The viewer switched the diff layout.     |

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

`granularity: "token_range"` adds `selection_text` and `selection_offset`.
The UI and the comments API can write it, but `Reviews.Anchoring.relocate/3`
returns `{:error, :not_implemented}` for it, so token-range threads do not
move across patchsets yet.
