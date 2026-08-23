# Code storage and LSP integration for review hunks

**Status:** Draft for discussion

**Created:** 2026-08-23

**Owner:** Unassigned

## Summary

Reviews currently uploads a unified diff. That is enough to render changed
lines, but it is not enough to run a language server. An LSP server needs a
complete project tree for both sides of the diff.

Add a code-storage boundary that accepts Git objects from `reviews push` and
stores two immutable refs for each patchset:

- `base_ref` resolves to the repository state on the old side of the diff.
- `head_ref` resolves to the repository state on the new side of the diff.

The Reviews backend attaches those refs to the patchset. An isolated LSP runner
can then materialize either ref and answer requests from the hunk viewer.

The first UI feature should be symbol hover on changed lines. Definition and
reference navigation should follow only after Reviews has a policy for exposing
unchanged source files.

## Current system

The existing path is synchronous:

1. `cli/src/commands/push.rs` calls `git::capture_diff`.
2. `cli/src/git.rs` returns `raw_diff`, `base_sha`, and `branch_name`.
3. The CLI posts that payload to `POST /api/v1/reviews` or
   `POST /api/v1/reviews/:slug/patchsets`.
4. `Reviews.Reviews` stores the raw diff on a patchset and stores one parsed row
   per changed file.
5. `ReviewLive` sends each hunk's raw diff to the `DiffRenderer` JavaScript
   island. The island renders it with `@pierre/diffs`.

There is no source-repository storage, background job system, or LSP process
manager. `base_sha` is descriptive metadata. The server cannot resolve it.

The current diff capture also needs more precise ref semantics:

- `A..B` compares commit A with commit B.
- `A...B` compares the merge base of A and B with B.
- `--range HEAD` compares HEAD with tracked working-tree state.
- The staged fallback compares HEAD with the Git index.

The last two cases do not have a real head commit. The CLI must create one
locally before it uploads code.

## Goals

- Give every code-enabled patchset exact, immutable base and head Git refs.
- Preserve the diff-only workflow when code storage is disabled.
- Support committed, staged, and tracked working-tree changes.
- Keep the storage provider behind a server-side interface.
- Run language servers outside the Phoenix web process.
- Let the hunk viewer request LSP data for a visible old-side or new-side
  position.
- Keep full repository contents out of LiveView state and browser responses.
- Make storage cleanup, request limits, and failure states observable.

## Non-goals

- Hosting a general-purpose Git forge.
- Fetching a user's source repository from GitHub or another remote.
- Uploading untracked files, Git LFS objects, or submodule contents in v1.
- Installing project dependencies or running project build scripts.
- Supporting every language server at launch.
- Sending diagnostics for every file as soon as a review opens.
- Replacing the existing raw-diff renderer.
- Exposing arbitrary unchanged files before the access policy is settled.

## Terms

- **Code repository:** The storage namespace associated with one Reviews
  review. Patchsets in that review share Git objects but use distinct refs.
- **Code snapshot:** The base/head ref pair attached to one patchset.
- **Synthetic commit:** A local commit object created by the CLI to represent
  staged or tracked working-tree state. It does not change the user's branch.
- **LSP runner:** An isolated service that checks out a snapshot and owns
  language-server processes.

## Proposed architecture

```text
reviews push
    |
    | 1. reserve snapshot
    v
Phoenix API -------------------------> Postgres
    |                                    |
    | short-lived upload target          | patchset -> code snapshot
    v                                    |
Code storage <---------------------------+
    |
    | immutable base/head refs
    v
Isolated LSP runner <-------------- Phoenix / ReviewLive
                                         |
                                         v
                                DiffRenderer hunk island
```

The Phoenix application owns authorization, metadata, and response filtering.
The code-storage provider owns Git objects and refs. The LSP runner owns
checkouts and language-server processes.

Do not start language servers under a Phoenix request process. Language servers
consume significant memory, have variable startup time, and may inspect or
execute repository configuration.

## Key decisions

### Store refs per patchset

Attach the snapshot to a patchset, not only to a review. Patchsets are
append-only, and each one can have different base and head states.

Use provider-generated ref names such as:

```text
refs/reviews/<code_repository_id>/snapshots/<code_snapshot_id>/base
refs/reviews/<code_repository_id>/snapshots/<code_snapshot_id>/head
```

Clients cannot choose the namespace. Code storage must reject updates to a ref
after it first resolves successfully.

Store both the ref name and expected object ID. A ref is ready only after the
provider confirms that it resolves to the expected commit.

### Use one storage namespace per review

All patchsets in one review should share a code repository. Git can then reuse
objects between uploads. Do not deduplicate objects across reviews in the first
version. Review-level isolation makes authorization and deletion easier to
audit.

### Represent uncommitted state with a synthetic commit

The CLI must never commit on the user's branch. It creates Git objects directly
and pushes only the reserved storage refs.

For a committed range, the resolved end commit is the head commit. For staged
or tracked working-tree state, the CLI creates a tree and then calls
`git commit-tree` with the base commit as its parent. The resulting commit is
only a transport snapshot.

Use a fixed synthetic author and committer identity such as
`Reviews Snapshot <snapshot@reviews.invalid>`. Do not copy a developer's local
Git name or email into the uploaded commit. The commit message must not contain
the local checkout path or remote URL.

The synthetic tree must match the diff payload. After it creates the tree, the
CLI should generate `raw_diff` from `base_oid` to `head_oid`. This makes the
rendered diff and LSP workspace two views of the same objects.

### Keep code storage optional at the protocol boundary

Servers advertise the feature through `GET /api/v1/capabilities`. An older
server can return `404`; the CLI treats that as code storage disabled.

When storage is disabled, the current push payload and behavior remain valid.
When storage is enabled, server configuration chooses one of two policies:

- `optional`: warn on upload failure, then create the diff-only patchset.
- `required`: abort the push before creating the patchset.

Use `optional` during rollout. A CLI flag such as `--no-code-storage` must let a
user skip repository upload unless the server requires it.

## Snapshot creation in the CLI

Extend `CapturedDiff` with:

```text
base_oid
head_oid
object_format       # sha1 or sha256
head_kind           # commit, index_snapshot, or worktree_snapshot
```

Resolve each input mode as follows:

| CLI input | Base | Head |
| --- | --- | --- |
| `A..B` | `rev-parse A` | `rev-parse B` |
| `A...B` | `merge-base A B` | `rev-parse B` |
| default committed range | `HEAD~1` | `HEAD` |
| staged fallback | `HEAD` | synthetic commit from the index |
| single revision such as `--range HEAD` | the revision | synthetic commit from tracked working-tree state |

For a worktree snapshot, start with a temporary index. Include paths already
tracked by Git, including staged additions. Apply worktree deletions. Do not add
untracked or ignored paths. Never replace the user's real index.

Before upload, verify these invariants locally:

```text
git diff --binary <base_oid>..<head_oid> == raw_diff
base_oid^{commit} exists
head_oid^{commit} exists
```

The comparison should normalize only the final newline emitted by the command.
If the invariant fails, stop the code upload instead of attaching mismatched
refs.

### Repository edge cases

- **Shallow clone:** allow it when Git can send all objects needed for the two
  commits and their trees. Do not make the server fetch missing history.
- **Submodules:** upload the gitlink entries only. Do not recurse in v1.
- **Git LFS:** upload pointer files only. Report that semantic results can be
  incomplete when a language server needs LFS content.
- **Untracked files:** exclude them. A later flag can opt them in with an
  explicit size and secret warning.
- **Binary files:** generate the canonical diff with `--binary`, even though
  the LSP path will normally ignore binary files.
- **SHA-256 repositories:** carry `object_format` through the protocol. A
  backend may reject an unsupported object format before upload.

## Upload protocol

Use a reserve, upload, verify, and claim flow. This prevents a visible patchset
from pointing at refs that were never uploaded.

### 1. Discover capability

`GET /api/v1/capabilities` returns:

```json
{
  "code_storage": {
    "enabled": true,
    "required": false,
    "supported_object_formats": ["sha1"],
    "max_upload_bytes": 536870912
  },
  "lsp": {
    "enabled": true,
    "languages": ["elixir"]
  }
}
```

All limits are configuration values. The values above are examples, not fixed
product limits.

### 2. Reserve a snapshot

`POST /api/v1/code-snapshots` requires an API token.

```json
{
  "review_slug": "k7m2qz",
  "object_format": "sha1",
  "base_oid": "<full object id>",
  "head_oid": "<full object id>"
}
```

Omit `review_slug` for a new review. Include it for `reviews push --update`.

Response `201`:

```json
{
  "id": "<snapshot uuid>",
  "repository_id": "<repository uuid>",
  "upload": {
    "remote_url": "https://code.example.test/git/<opaque id>",
    "token": "<short-lived credential>",
    "expires_at": "2026-08-23T18:30:00Z"
  },
  "refs": {
    "base": "refs/reviews/.../base",
    "head": "refs/reviews/.../head"
  }
}
```

The CLI pushes both refs in one atomic Git operation when the provider supports
it. It sends the short-lived credential as an HTTP authorization header. It
must not put credentials in the remote URL, Git config, logs, or error text.

The storage service must scope the credential to the returned repository and
two ref names. It must reject any other ref update.

### 3. Verify the upload

`POST /api/v1/code-snapshots/:id/complete` asks the provider to resolve both
refs and compare them with the reserved object IDs.

Response `200`:

```json
{
  "id": "<snapshot uuid>",
  "status": "ready",
  "base_oid": "<full object id>",
  "head_oid": "<full object id>"
}
```

Completion is idempotent. A mismatch sets the snapshot to `failed` and does
not expose either ref to an LSP runner.

### 4. Claim the snapshot

Add an optional `code_snapshot_id` to both existing push requests. The create
or append transaction checks that:

- the snapshot is `ready`;
- the current identity reserved it;
- it has not been claimed by another patchset;
- its repository belongs to the target review, or is an unclaimed repository
  for a new review.

The transaction then attaches the code repository to the review and the code
snapshot to the patchset.

Unclaimed reservations expire after a configurable period. Cleanup removes
their refs and database rows.

### Durable state transitions

Keep upload, verification, claim, and deletion state in Postgres. Provider
operations must be idempotent so a restart can resume them.

The current application has no durable job system. The first implementation can
use a supervised periodic sweeper that claims eligible rows with database
locks. The database status remains the source of truth, so a crashed sweeper
does not lose work. If later storage volume needs a job queue, this state
machine remains the contract and the queue only schedules attempts.

## Server-side storage interface

Define a behavior such as `Reviews.CodeStorage` instead of calling one vendor
from controllers or contexts.

```elixir
@callback reserve(repository, snapshot, actor) ::
  {:ok, upload_instructions} | {:error, reason}

@callback verify(repository, snapshot) ::
  {:ok, %{base_oid: String.t(), head_oid: String.t()}} | {:error, reason}

@callback checkout_source(repository, ref, destination) ::
  :ok | {:error, reason}

@callback delete_snapshot(repository, snapshot) :: :ok | {:error, reason}
@callback delete_repository(repository) :: :ok | {:error, reason}
```

The exact checkout callback can instead live on a private code-storage service
API. The important boundary is that Phoenix and the LSP runner use opaque
repository keys. They do not construct filesystem or object-store paths.

Provide these implementations in order:

1. `Disabled`, for the current behavior and tests that do not need source.
2. `LocalGit`, backed by bare repositories on a persistent volume for local
   development and self-hosting.
3. A remote service adapter when the production storage target is selected.

An object bucket alone is not a Git smart-HTTP remote. A bucket-backed provider
therefore needs either a code-storage service in front of it or a different
bundle-upload contract behind the same behavior.

## Data model

Add `code_repositories`:

| Field | Purpose |
| --- | --- |
| `id` | Internal identifier, preferably a UUID for external use |
| `review_id` | Nullable while the first upload is staged; unique when set |
| `owner_id` | Identity that created the repository reservation |
| `backend` | Configured provider name |
| `storage_key` | Opaque provider locator; never sent to the browser |
| `object_format` | `sha1` or `sha256` |
| `status` | `staging`, `ready`, `failed`, or `deleting` |
| `last_error` | Redacted operational error |
| `expires_at` | Cleanup deadline while unclaimed |
| timestamps | Audit and retention data |

Add `code_snapshots`:

| Field | Purpose |
| --- | --- |
| `id` | Public reservation identifier |
| `code_repository_id` | Storage namespace |
| `patchset_id` | Nullable until claimed; unique when set |
| `reserved_by_id` | Identity allowed to claim it |
| `base_ref`, `head_ref` | Provider-generated immutable refs |
| `base_oid`, `head_oid` | Expected full commit IDs |
| `head_kind` | `commit`, `index_snapshot`, or `worktree_snapshot` |
| `status` | `reserved`, `uploading`, `ready`, `claimed`, `failed`, or `expired` |
| `last_error` | Redacted verification or cleanup error |
| `expires_at` | Deadline for an unclaimed snapshot |
| timestamps | Audit data |

Use database constraints to prevent two patchsets from claiming one snapshot
and to prevent two code repositories from attaching to one review.

Do not add raw credentials, repository URLs, source archives, or LSP responses
to Postgres.

## LSP request path

### Position mapping

An LSP position is zero-based and its character offset is measured in UTF-16
code units unless a server negotiates another encoding. Diff line numbers are
one-based.

The renderer must send:

```json
{
  "request_id": "<browser-generated id>",
  "patchset_number": 2,
  "side": "new",
  "file_path": "lib/reviews/reviews.ex",
  "position": {"line": 41, "character": 17},
  "method": "textDocument/hover"
}
```

The JavaScript boundary converts the visible line and token offset to the
negotiated LSP encoding. The server validates the file and line against the
selected patchset before forwarding the request.

Snapshot selection is deterministic:

- `side: "old"` uses `base_ref` and `old_path` for a rename.
- `side: "new"` uses `head_ref` and the new path.
- Added files support only the new side.
- Deleted files support only the old side.

### LiveView integration

Add an `lsp_request` event to the existing `DiffRenderer` hook contract. Include
the hunk island ID and `request_id` so concurrent islands cannot consume each
other's results.

`ReviewLive` should start the request asynchronously and keep rendering while
the runner starts. It pushes one of these scoped events back to the island:

```text
lsp_result:<island_id>
lsp_error:<island_id>
```

Ignore a result when its `request_id` is no longer current. Debounce pointer
hover and cancel superseded work. Limit each viewer to a small configurable
number of concurrent requests.

Do not pass raw LSP protocol objects directly to the browser. Normalize each
supported method into a versioned Reviews response. Sanitize Markdown before
rendering it and enforce response byte limits.

### Initial UI

Start with `textDocument/hover` on tokens in changed lines:

- Pointer users see a delayed hover card.
- Keyboard users can focus a token and open the same card.
- A loading state appears only after a short delay to avoid flicker.
- The card distinguishes `unavailable`, `starting`, `ready`, and `error`.
- Existing line and token comment gestures remain available.

Do not make a plain token click mean both “comment” and “open symbol.” Keep the
existing comment action and use hover, focus, or a separate symbol action for
LSP data.

Definition and reference results can return a path and range in the first
version, but the browser must not fetch unchanged source content. A later source
viewer can add that capability after the access policy is approved.

## LSP runner

Create a separate runner interface, for example:

```text
open_session(code_repository_id, snapshot_id, side, language)
request(session_id, method, file_path, position)
close_session(session_id)
```

Cache a session by repository, snapshot, side, language, and project root.
Expire idle sessions after a configurable period. Bound total sessions per
runner and evict the least recently used idle session when needed.

Use a language registry to define:

- file extensions and language IDs;
- root markers and monorepo root selection;
- the pinned server executable or container image;
- initialization options and position encoding;
- supported methods;
- startup, request, memory, and output limits.

Launch with one language in production. A fake deterministic LSP server should
cover integration tests without installing a real toolchain.

### Isolation requirements

Treat every uploaded repository and language server as untrusted.

- Run each workspace as an unprivileged user in a container or microVM.
- Mount source read-only after checkout.
- Provide a separate size-limited temporary directory.
- Disable outbound network access.
- Set CPU, memory, process-count, file-count, and wall-clock limits.
- Do not run Git hooks, dependency installers, build scripts, or editor tasks.
- Pin language-server versions and images.
- Remove environment secrets before process start.
- Validate all requested paths after normalization. Reject absolute paths,
  `..`, symlink escapes, and URIs outside the workspace.
- Truncate logs and protocol payloads. Redact upload credentials and storage
  keys.

Some language servers execute repository code during initialization even when
Reviews does not ask them to. The sandbox is a launch requirement, not a later
hardening task.

## Access and disclosure policy

This is the main product decision that must be resolved before enabling LSP in
production.

A link-visible review currently exposes only the uploaded diff and packet.
Uploading a complete repository does not by itself change that browser
contract. LSP hover text, definitions, diagnostics, and source navigation can
still reveal names or contents from unchanged private files.

Recommended first policy:

- Keep raw code storage private to backend services.
- Let link viewers see the existing diff as they do today.
- Require sign-in for LSP requests.
- Limit the first release to hover responses requested from changed lines.
- Filter locations outside changed files to path and range only.
- Do not add an arbitrary file-content endpoint.
- Record the requesting identity, review, snapshot, method, and result size in
  an audit event without recording source content.

This policy lets signed-in reviewers use semantic help without silently turning
a review link into full repository access. It does not replace a real review
membership model. Full definition navigation should wait for that model or for
an explicit review-level option that warns the author about the broader
disclosure.

## Retention and deletion

- Keep claimed snapshot refs for the lifetime of their review by default.
- Expire unclaimed uploads after a short configurable period.
- Delete LSP workspaces when their session expires.
- On review deletion, mark storage as deleting, remove provider refs and
  objects, then remove database rows.
- Make deletion idempotent and retryable.
- Expose storage age and deletion failures to operators.
- Do not rely on database cascade alone. Provider cleanup must complete or
  remain visible as failed work.

If Reviews later adds review archival, define a separate storage-retention
policy. Do not assume archive means delete.

## Failure behavior

Use stable error codes across providers:

```text
code_storage_disabled
unsupported_object_format
repository_too_large
upload_expired
ref_mismatch
snapshot_not_ready
snapshot_not_authorized
lsp_language_unsupported
lsp_start_timeout
lsp_request_timeout
lsp_response_too_large
lsp_workspace_unavailable
```

The CLI should distinguish these states:

- Diff pushed with semantic code unavailable.
- Push aborted because code storage is required.
- Upload reserved but expired before claim.
- Snapshot uploaded but server verification failed.

The hunk UI should treat LSP failure as a local enhancement failure. It must not
break diff rendering, comments, or review decisions.

## Observability

Record metrics for:

- reservation, upload, verification, and claim duration;
- bytes and object counts per repository and snapshot;
- unclaimed and failed snapshots;
- LSP cold-start and warm-request latency by language;
- active sessions, evictions, timeouts, crashes, and sandbox limit exits;
- response sizes and filtered result counts;
- cleanup age and provider deletion failures.

Correlate CLI, Phoenix, storage, and runner logs with `code_snapshot_id`. Do not
use ref names, local paths, repository names, or source text as metric labels.

## Rollout plan

### Phase 0: contracts and disabled adapter

- Add the tables, schemas, capability endpoint, and `Disabled` adapter.
- Add optional `code_snapshot_id` fields to the existing push contracts.
- Keep all deployed behavior unchanged.

### Phase 1: source snapshot upload

- Implement CLI ref resolution and synthetic commits.
- Implement `LocalGit` storage and upload verification.
- Show snapshot status to the review author and operators.
- Exercise create-review and append-patchset uploads end to end.
- Do not expose an LSP UI yet.

### Phase 2: one-language hover

- Deploy the isolated runner with one pinned language server.
- Add changed-line hover requests and normalized hover responses.
- Enforce sign-in, rate limits, timeouts, and audit events.
- Measure cold starts and storage cost before adding languages.

### Phase 3: navigation and remote storage

- Add the production code-storage adapter.
- Add more languages through the registry.
- Add definition and reference navigation only with an approved unchanged-code
  access policy.

## Test plan

### Rust CLI

- Resolve `A..B` and `A...B` to the correct base and head commits.
- Build an index snapshot without changing the real index or branch.
- Build a tracked worktree snapshot without adding untracked files.
- Prove that the generated raw diff matches the synthetic refs.
- Push only the two reserved refs to a temporary bare Git repository.
- Never print a returned upload credential.
- Fall back correctly against an old or code-storage-disabled server.

### Phoenix contexts and API

- Enforce snapshot state transitions and unique claims.
- Reject a snapshot reserved by another identity.
- Reject a snapshot for the wrong review repository.
- Verify ref/OID mismatches and expired credentials.
- Create and append patchsets with and without a snapshot.
- Keep existing API clients compatible.
- Clean up expired, failed, and deleted snapshots idempotently.

### LSP path

- Map old, new, added, deleted, and renamed file positions to the correct ref.
- Convert Unicode token offsets to the negotiated position encoding.
- Reject paths outside the workspace and positions outside the patchset.
- Route concurrent island responses by island ID and request ID.
- Cancel superseded hover requests.
- Sanitize Markdown and truncate oversized responses.
- Preserve diff rendering and commenting when the runner is down.

### End to end

Use a temporary Git repository, `LocalGit`, and a fake LSP server:

1. Create two committed files and one staged change.
2. Run `reviews push` and verify the base/head refs.
3. Open the review and request hover data on the changed line.
4. Append a patchset and verify that it reuses the code repository but creates
   new immutable refs.
5. Confirm that the earlier patchset still resolves to its original refs.
6. Delete the review and verify provider cleanup.

## Acceptance criteria

1. A committed-range push can attach verified base and head refs to patchset 1.
2. A staged or tracked worktree push attaches a synthetic head ref whose diff
   matches the rendered raw diff.
3. `reviews push --update` creates a new ref pair without changing an earlier
   patchset's refs.
4. A code-storage failure does not corrupt or partially attach a patchset.
5. With the optional policy, a storage failure can still produce a diff-only
   review and a clear CLI warning.
6. With the required policy, the same failure stops before review creation.
7. A signed-in viewer can request hover data for a changed line in a supported
   language.
8. Old-side and new-side requests run against their respective refs.
9. Anonymous viewers and unsupported languages get a stable unavailable state.
10. The diff viewer, comments, packets, and section decisions work when the LSP
    runner is unavailable.
11. The runner has no network access or application secrets and cannot escape
    its workspace through a requested path.
12. Deleting a review schedules visible, retryable cleanup of its code storage.

## Open questions

1. **Which production code-storage service should own Git smart HTTP and
   persistent objects?** `LocalGit` is enough for development, but the cloud
   adapter determines the upload credential and checkout contracts.
2. **Who may receive semantic results?** The recommended first policy requires
   sign-in and restricts results, but Reviews does not yet have review
   membership or repository-level grants.
3. **Which language should launch first?** Choose one with a pinned server image
   and a representative repository. Elixir is a natural dogfood target for
   Reviews itself, but it can have a higher cold-start and dependency cost than
   a simpler server.
4. **What are the upload and retention limits?** Set them from expected private
   repository sizes and storage cost. Do not inherit the existing 50 MB JSON
   body limit.
5. **Should hosted production eventually require code storage?** Keep it
   optional until upload reliability, privacy messaging, and cleanup have been
   proven.

## Likely code touchpoints

- `cli/src/git.rs`: resolve exact snapshot commits and create synthetic ones.
- `cli/src/commands/push.rs`: reserve, upload, verify, and claim snapshots.
- `cli/src/api.rs`: capability and code-snapshot API contracts.
- `lib/reviews/reviews.ex`: claim a ready snapshot in the patchset transaction.
- `lib/reviews/reviews/patchset.ex`: associate a patchset with its snapshot.
- `lib/reviews_web/controllers/api/`: capability and snapshot endpoints.
- `lib/reviews/review_view.ex`: expose only LSP availability, never storage
  credentials or keys.
- `lib/reviews_web/live/review_live.ex`: authorize and run asynchronous LSP
  requests.
- `assets/js/hooks/diff_renderer.js`: request and render scoped hover results.
- `assets/js/schemas.js`: validate the new browser wire contracts.
- `config/runtime.exs`: select storage policy, provider, runner, and limits.
- `lib/reviews/application.ex`: supervise only lightweight clients and cleanup
  coordination, not language-server processes.
