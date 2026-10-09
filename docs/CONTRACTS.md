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

Query params (all optional):

| Param    | Values                           | Default | Meaning |
| -------- | -------------------------------- | ------- | ------- |
| `role`   | `all`, `authored`, `involved`    | `all`   | `authored`: one of your identities wrote it. `involved`: someone else wrote it and you took part. |
| `status` | `all`, `open`, `updated`         | `all`   | `open`: has open threads. `updated`: has a patchset newer than your last action on it. |
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
`last_activity_at`.

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
