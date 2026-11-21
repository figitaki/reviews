# Language server support in Reviews

**Status:** Proposal for review. No code yet.
**Builds on:** [`.plans/lsp-code-storage-integration.md`](../../.plans/lsp-code-storage-integration.md) (#74), code storage Phases 0 and 1 (#80), and issue #146.

## Summary

Reviewers should be able to see what a changed symbol is, where it is defined and who uses it, against the exact revision under review. Agents should get the same answers through MCP.

**Recommendation:** run language servers on the server, against code storage, **once per patchset, in a batch job**. The job asks the language server about the identifiers in the diff and stores the answers. The diff view and the MCP tools read the stored answers. Nobody talks to a live language server while reading a review.

Start with TypeScript and JavaScript, then Python and Go. Elixir and Rust come later, because their language servers have to compile the project, and compiling runs the project's own code.

This changes one decision in the existing plan. That plan keeps a live language-server session per snapshot and answers hover on demand. Precomputing is cheaper, has a fixed cost per patchset, keeps no state between requests, and gives MCP the same data for free.

## What it is for

In order of value to a reviewer:

1. **Hover on identifiers in the diff:** type, signature and doc comment. This answers "what is this?" without leaving the review.
2. **Go to definition:** for a symbol defined in the diff, jump to its hunk. For a symbol defined elsewhere, show the path, line and signature.
3. **References for symbols the diff defines or changes:** "this function changed; here are its 14 callers, 3 of them outside the diff." This is the question a review most needs answered, and today a reviewer has to answer it in their own checkout.
4. **Diagnostics the patchset introduces:** type errors and warnings on head that base does not have, limited to changed files. Shown as markers in the diff and as a count on the review. It is a cheap "does this even type-check" signal, separate from CI.
5. **MCP:** the same data as read tools, so an agent reviewing through MCP can follow a symbol without cloning the repository.

Not in scope: completion, rename, code actions, formatting, or anything that edits code. Reviews is read-only on source.

## Where language servers run

| Option | For | Against |
|---|---|---|
| **CLI at push time** | The author's machine has the toolchain and dependencies, and the project is already built. No server compute. | Slows every push, needs the toolchain installed wherever `reviews push` runs (agents often push from bare sandboxes), and results vary by machine. The server cannot check results against the snapshot. |
| **Live server sessions against code storage** (existing plan) | Answers any position, including unchanged lines. | A session manager, warm pools, cold starts the reader waits through, and cost that grows with reading traffic instead of pushes. Hard to serve to MCP within its byte and rate budgets. |
| **Batch job per patchset against code storage** (recommended) | Runs once per pushed patchset, so cost follows pushes. Results are fixed for that patchset, cacheable forever, and the same for the web and MCP. No reader ever waits on a cold start. | Answers only what was precomputed: identifiers in the visible diff, not arbitrary unchanged files. A new patchset waits a minute or two for its results. |
| **Static or syntactic indexing only** (tree-sitter, ctags) | Cheap, never runs project code, covers many languages. | No types, and definitions are guesses. Worth keeping as a fallback for unsupported languages, not as the main feature. |

The batch job still uses real language servers. It opens the snapshot, sends `textDocument/hover`, `definition` and `references` for each identifier in the diff, collects `publishDiagnostics`, and stores normalized results. Where a SCIP indexer exists for the language (scip-typescript, scip-python), it can replace the language server inside the job without changing anything downstream.

The CLI path stays open for later: `reviews push --index <file>` could upload a SCIP index the author built locally, for languages the server cannot build safely. Those results would be shown as supplied by the author.

## How it fits the current code

- **Code storage (#80).** Each claimed patchset has a `CodeSnapshot` with `base_oid` and `head_oid`. The `checkout_source/3` callback exists in `Reviews.CodeStorage` but both adapters return `{:error, :not_implemented}`. In the code.storage adapter, snapshot refs are **mutable**: the upload token allows fast-forwards and deletion, and `delete_snapshot/2` is a no-op. The job must therefore check out **by OID** and fail if the commit it gets is not `head_oid` (or `base_oid`). Before building, confirm that code.storage serves a fetch by commit ID. If it does not, fetch the snapshot branch and compare.
- **Patchsets and packets.** Results are keyed by patchset, file path, side and line. Packets do not change. A hunk shown in a packet section gets the same results as in the full diff, because both render from the same hunk rows.
- **Diff view.** `DiffRenderer` (`assets/js/hooks/diff_renderer.js`) mounts Pierre per hunk. Selecting text already creates a token comment anchor (`kind: "token"`, `lineCharStart`). Code intelligence must not take over that gesture. Hover and keyboard focus open the card. Definition and references are buttons in the card. The island receives the results for its hunk with the rest of its dataset, validated in `assets/js/schemas.js`. There is no per-hover round trip.
- **MCP.** Add read tools next to `reviews_get_file_diff`, for example `reviews_get_symbol` (hover and definition at a path, side and line) and `reviews_find_references`. They page through `ReviewsWeb.MCP.Budget` like the other reads, and they answer "not indexed" or "pending" explicitly instead of returning nothing.
- **Capabilities.** `GET /api/v1/capabilities` already returns `lsp: %{enabled: false, languages: []}`. Fill it in from the language registry.

## The job

1. A patchset is claimed with a ready snapshot. Postgres records an index row per side (`pending`). The existing sweeper pattern can pick it up. Reviews has no job queue yet, and this does not need one.
2. A runner checks out the OID into a fresh, read-only workspace. Base can be skipped when another patchset in the same review already indexed that `base_oid`.
3. For each supported language in the changed files, the runner starts the pinned language server, waits for it to finish loading the project, and queries the identifiers on changed and context lines in the diff, both sides.
4. It normalizes results into a Reviews format (not raw LSP JSON), sanitizes Markdown, enforces size limits, and stores them. Status becomes `ready`, `partial` (some limit hit) or `failed`, each with a reason the UI can show.

Runner isolation is a launch requirement, as in the existing plan: no network, no secrets in the environment, a separate unprivileged sandbox (a Fly Machine per job is the obvious fit for this deployment), CPU, memory and time limits, and no dependency install, build scripts or Git hooks.

## Languages first

| Language | Server | Needs to run project code? | Order |
|---|---|---|---|
| TypeScript, JavaScript | typescript-language-server / tsserver, or scip-typescript | No. Types load from the tree. Missing `node_modules` makes imported types `any`, but local code still resolves. | 1 |
| Python | Pyright, or scip-python | No. | 2 |
| Go | gopls | No code execution, but resolving modules needs a module cache or network. Start with what resolves offline. | 3 |
| Rust | rust-analyzer | Yes: build scripts and proc macros. Needs a sandbox we trust for it, or author-supplied indexes. | Later |
| Elixir (Reviews itself) | Expert / ElixirLS | Yes: compiling evaluates `mix.exs` and macros, and needs `deps`. | Later |

Without installed dependencies, every language loses some cross-package results. That is acceptable for a first version as long as the UI says "defined in a dependency" rather than showing nothing.

## Cost, caching and limits

**Cost follows pushes, not readers.** One job per patchset side. As a rough estimate to verify in Phase 1, a medium TypeScript repository loads in one to three minutes on a 2 CPU, 4 GB machine. With base reuse, that is a few machine-minutes per patchset: cents, not dollars, at on-demand prices. Reading a review costs a database read.

**Caching.** Results are immutable for a given OID, path and line, so they never expire while the review exists. The job keys work by OID, so repeated pushes of the same base do not redo it. Checkouts are thrown away after each job. Results are deleted when the review is deleted (#202), alongside the code storage repository.

**Limits, all configurable, with suggested starting values:**

- Checkout size: 500 MB and 50,000 files. Above that, skip with reason `repository_too_large`.
- Wall clock: 5 minutes per side, including the language server's start.
- Identifiers queried: 5,000 per patchset. References: 200 per symbol, and only for symbols defined or changed in the diff.
- Stored result size: 5 MB per patchset.
- Concurrency: 2 jobs per account at a time, plus a global cap and a kill switch (`LSP_ENABLED`).
- Patchsets with no snapshot, or with no supported language, cost nothing.

## Access and disclosure

Today any review is readable by anyone with its link (`Reviews.Policy.can?(_, :read, _)` is always true), and the review shows only the diff and packet. Hover text, definition snippets and references reveal unchanged code. The existing plan's proposal still stands, and Carey needs to confirm it:

- Results inside the diff are visible to everyone who can see the review.
- Results that point outside the diff (a definition's signature, a caller's path and line) are shown to signed-in viewers only, as path, line and one signature or call-site line. There is no endpoint that returns whole unchanged files.
- The author can turn code intelligence off per push (`--no-code-intel`) or per review.

## Phases

1. **Checkout and runner.** Implement `checkout_source` by OID in the code.storage adapter. Build the sandboxed runner and the index state machine with a fake language server. Measure checkout time and size on real repositories. Nothing visible to users.
2. **TypeScript hover and definition in the diff view.** One language, changed and context lines, card on hover or focus, definition jumps to a hunk or shows path and signature. Behind a flag on previews first.
3. **References and diagnostics.** References for symbols the diff defines or changes, and diagnostics introduced by the patchset, shown in the diff and as a count on the review.
4. **MCP tools.** `reviews_get_symbol`, `reviews_find_references` and diagnostics on the existing file diff read, with the same disclosure rules.
5. **More languages.** Python, then Go. Then decide between a stronger sandbox and author-supplied indexes for Rust and Elixir.

Each phase can be stopped after without leaving dead code in the review page: until Phase 2 ships, the UI does not change.

## Questions for Carey

1. **Precompute or live sessions?** This doc recommends batch precompute per patchset over the existing plan's live hover sessions. The trade is coverage of unchanged lines for fixed cost, no cold starts, and free MCP support. Agree?
2. **Disclosure.** Is it acceptable for signed-in viewers to see a signature line or call-site line from unchanged files? Should link viewers see in-diff results? Should code intelligence be on by default when code storage is on, or opt-in per push?
3. **First language.** TypeScript/JavaScript is the safest start. Is dogfooding on Reviews (Elixir) important enough to change that, given that it means compiling untrusted projects or accepting author-supplied indexes?
4. **Diagnostics.** Are introduced diagnostics wanted in Reviews, or do they overlap too much with CI to be worth it?
5. **Where the runner runs and the budget.** Fly Machines per job in the same organization, or a separate service? What monthly ceiling should the kill switch enforce?
6. **Author-supplied indexes.** Should `reviews push --index` be on the roadmap, and should those results be marked as coming from the author?
7. **Code storage.** Should Reviews ask code.storage for immutable snapshot refs, or is checkout by OID enough? And who checks that code.storage supports fetching by commit ID?
