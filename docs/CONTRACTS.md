# Reviews — interface contracts

Stream 1 (this doc) defines the wire contracts that Stream 2a (LiveView + React)
and Stream 2b (Rust CLI) build against. Anything not listed here is undefined
and will probably change; if you need it, ping Stream 1 first.

---

## REST API — for the Rust CLI (Stream 2b)

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
  "raw_diff": "diff --git a/lib/foo.ex b/lib/foo.ex\n..."
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
  "raw_diff": "diff --git a/lib/foo.ex ..."
}
```

Response `201`:

```json
{ "patchset_number": 2, "url": "http://localhost:4000/r/k7m2qz" }
```

Unknown slug → `404`.

### `GET /api/v1/me`

Powers `reviews whoami`. Response `200`:

```json
{ "username": "careyjanecka", "email": "carey@example.com" }
```

### Body size

`Plug.Parsers` is configured with `length: 50_000_000` so diffs up to ~50 MB
go through. If you need to push something larger, talk to Stream 1.

---

## LiveView `DiffRenderer` hook — for the React island (Stream 2a)

The hook is registered in `assets/js/app.js` under the name `DiffRenderer`.
Each per-file element in `ReviewsWeb.ReviewLive` carries `phx-hook="DiffRenderer"`,
a unique DOM id, and `phx-update="ignore"` (the hook owns its DOM tree).

### `data-*` props on mount

| Attribute              | Type     | Description                                              |
| ---------------------- | -------- | -------------------------------------------------------- |
| `data-file-path`       | string   | The file's path in the diff (`lib/foo.ex`).              |
| `data-file-status`     | string   | `"added"`, `"modified"`, `"deleted"`, or `"renamed"`.    |
| `data-patchset-number` | string   | The patchset number this file belongs to.                |
| `data-side`            | string   | `"old"` or `"new"` — which side the file is anchored on for new comments. Stream 2a hard-codes `"new"`.|
| `data-raw-diff`        | string   | Raw unified-diff substring for **this file only** (between two `diff --git` markers). The hook parses it client-side. |
| `data-threads`         | string (JSON) | Array of published threads anchored in this file. Shape: `[{ id, side, anchor, status, author: { username }, comments: [{ id, body, author }] }]`. |
| `data-drafts`          | string (JSON) | Array of the **current viewer's** draft comments in this file. Shape: `[{ id, thread_id, side, anchor, body }]`. Other viewers' drafts are never sent. |

Stream 2a deferred wiring `@pierre/diffs`' React renderer (it needs a worker
pool + Shiki theme bootstrap) and instead ships a minimal client-side
unified-diff component inside the same hook. The data contract above is
forward-compatible — a future stream can replace the renderer without
changing what LiveView pushes down.

Example mount payload (from `dataset`):

```js
{
  filePath: "lib/reviews/accounts.ex",
  fileStatus: "modified",
  patchsetNumber: "2",
  side: "new",
  rawDiff: "diff --git a/lib/reviews/accounts.ex ...",
  threads: "[...]",
  drafts: "[...]"
}
```

### Events the hook PUSHES to LiveView

`this.pushEvent("save_draft", payload)`:

```json
{
  "thread_anchor": {
    "granularity": "line",
    "line_text": "  const userId = req.user.id;",
    "context_before": ["function getUser(req) {"],
    "context_after": ["  return db.users.findOne({ id: userId });"],
    "line_number_hint": 42
  },
  "body": "Should this be `String.to_existing_atom`?",
  "file_path": "lib/foo.ex",
  "line_text": "  const userId = req.user.id;",
  "side": "new"
}
```

`this.pushEvent("publish_review", payload)`:

```json
{ "summary": "Looks good, two nits inline." }
```

Both events are currently stubbed server-side — they log and return without
persisting. Stream 1 will wire them up to the contexts later.

### Events LiveView PUSHES to the hook

The hook registers `this.handleEvent(...)` for per-file thread refreshes
(scoped by file path so a publish in one file doesn't re-render every
mounted island):

| Event                            | Payload                       | Meaning                                         |
| -------------------------------- | ----------------------------- | ----------------------------------------------- |
| `threads_updated:<file_path>`    | `{ threads: [...], drafts: [...] }` | Either viewer drafts or published threads in this file changed; re-render with the new lists. |

The patchset-pushed banner is rendered by LiveView itself (no hook event) —
when LiveView receives `{:patchset_pushed, n}` on the `"review:<slug>"`
PubSub channel it assigns a banner message that the HEEx template displays.

### Events the hook PUSHES (extension to Stream 1's contract)

In addition to `save_draft` and `publish_review`, Stream 2a adds:

`this.pushEvent("delete_draft", { comment_id })` — remove a single draft
the viewer has previously saved.

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

`granularity: "token_range"` is reserved for v1.5 — `Reviews.Anchoring.relocate/3`
returns `{:error, :not_implemented}` for it today. Don't write threads with
that granularity from the v1 UI.
