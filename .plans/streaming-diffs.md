# Streaming diffs — all-expanded Changes view on one Pierre CodeView

Goal: make the classic Changes view (`/r/:slug`) render **every file diff
expanded by default**, fast, by (1) collapsing the per-hunk `@pierre/diffs`
islands into a single virtualized `CodeView`, and (2) streaming the raw diff
payloads to the client over the LiveView socket instead of inlining them in the
initial HTML.

## Decisions (locked)

Answered before this plan was written:

- **Architecture:** Single `CodeView` per patchset. Pierre owns virtualization,
  sticky headers, and selection. "All expanded" becomes the native state.
- **Scope:** **Changes view only.** The AI Review Packet view keeps its existing
  section-collapse UX and its per-hunk `FileDiff` islands, untouched. The two
  diff-rendering paths coexist after this work.

## Why the current design can't just "expand all"

The Changes view (`DiffComponents.diff_shell`, `diff_components.ex:90-117`)
renders one `PacketComponents.hunk_card` per file. Each card:

- Renders the Pierre island **only when expanded** —
  `<div :if={@expanded?} phx-hook="DiffRenderer" ...>` (`packet_components.ex:971`).
- Inlines the file's entire raw diff as a `data-raw-diff` HTML attribute
  (`packet_components.ex:982`).
- Mounts its own `Diffs.FileDiff` / `Diffs.VirtualizedFileDiff` with its own
  `Virtualizer` (`vanilla_renderer.js`).

So expanding everything today means: the full raw diff of every file in the
initial HTML payload, plus N island mounts each parsing + rendering + holding a
virtualizer. That cliff is exactly why `expanded_*` MapSets and the
`@changes_auto_open_line_limit` budget (`review_live.ex:35`) exist.

`CodeView` removes the cliff: it is "a mixed, virtualized list of files and
diffs in one scroll container" that "only renders what is visible." One
container, one virtualizer, off-screen files cost ~nothing — so "all expanded"
is free, and the budget logic can go away.

Note: in the Changes view a "card" is already **file-level** — `hunk_card` is
fed `ReviewHunks.combine_consecutive(hunks)` (`diff_components.ex:129`), i.e. all
of a file's hunks combined. So one `CodeView` item == one file maps cleanly;
there is no per-hunk granularity to preserve here.

## Target architecture

### Client: one CodeView

- New `assets/js/diff_renderer/code_view_renderer.js` — wraps `Diffs.CodeView`
  plus a single `Diffs.Virtualizer`, mirroring the structure of
  `vanilla_renderer.js`. Virtualizer is set up against the document/window
  (vanilla supports window scrolling) so the page keeps one natural scroll.
- New hook `assets/js/hooks/code_view.js` on a single
  `<div id="changes-code-view" phx-hook="CodeView" phx-update="ignore">`.
  It owns the CodeView instance and handles server pushes:
  - `code_view:add_items` → `codeView.addItems(items)` (streaming batches).
  - `code_view:update_threads` → recompute `lineAnnotations` for one file,
    `codeView.updateItem(...)`.
  - `code_view:set_diff_style` → re-render with `diffStyle` (one event, not
    one-per-file).
  - `code_view:scroll_to` → `codeView.scrollTo(itemId)` for file-tree / open-
    threads navigation.
- Reuse `annotation_ui.js` (composer, thread bubble, sign-in prompt),
  `lib/translate.js`, and `schemas.js` unchanged — `CodeView` shares the
  `lineAnnotations` / `onLineNumberClick` / `onTokenClick` / `renderAnnotation`
  props with `FileDiff`.
- Register `CodeView` in `app.js` alongside the existing hooks.

A CodeView **item** carries: a stable id (file path), the file's raw diff (or
pre-parsed `FileDiffMetadata`), status, and per-file `lineAnnotations`.

### Server: stream the diffs over the socket

This is the "streaming capabilities of LiveView" piece — the stateful socket is
used to push diff payloads progressively after the first paint, rather than
`stream/3` DOM streams (the diff body lives inside a `phx-update="ignore"`
island, so LV-managed DOM streaming does not apply).

- `mount/3` (connected) renders the page shell + the **empty** CodeView
  container, and assigns only **light file metadata** (path, status, +/−
  counts, viewed state) — no raw diffs in the render tree, no `data-raw-diff`.
- Streaming loop: `handle_info({:stream_diffs, cursor}, socket)` pops the next
  batch of files, reads each `File.raw_diff` (the column already exists —
  `file.ex`), builds CodeView item payloads, `push_event`s
  `code_view:add_items`, then reschedules itself with `send(self(), ...)` so the
  LiveView yields between batches and stays responsive.
- Kick off the first batch from the connected `mount/3` via `push_event` so the
  top of the page fills in one round-trip.
- On patchset switch / `{:patchset_pushed, n}`: push `code_view:reset` (or
  `setItems([])`) and restart the loop.

**Intelligent ordering.** Stream in file-tree order so the top of the viewport
fills first; make the **first batch small** (≈ first 6 files or ≈400 changed
lines, whichever comes first) for fast first paint, then larger batches
(≈30 files / ≈2000 lines). Constants tunable, defined next to the existing
`review_live.ex` budget constants. Optional later enhancement: client reports
scroll position and the server reprioritizes remaining batches — **not** in
scope for v1.

**Memory win.** Raw diffs no longer need to live in socket assigns for the whole
session: they are read per-batch from the `files` rows, pushed once, and then
owned by the client's CodeView. `ReviewView.snapshot` / `file_diff_meta`
(`review_view.ex:114-133`) gets a "light" path that skips loading `raw_diff`
into `file_diffs`; a separate per-batch fetch supplies the diff text.

### Expanded-by-default

With CodeView virtualizing, the Changes view drops:

- `expanded_file_ids`, and the changes-view use of `expanded_hunk_ids`.
- `@changes_auto_open_line_limit` and the `default_expanded_changes_hunk_ids` /
  `apply_changes_default_expansion?` / `maybe_apply_changes_default_expansion`
  machinery (`review_live.ex:1023-1057`) and
  `changes_default_expanded_patchset_ids`.
- `toggle_file_diff` / `toggle_hunk_diff` handlers for the Changes view.

(The packet view keeps `expanded_section_ids` / `expanded_hunk_ids` and the
`@section_*` constants — those are still its code paths.)

Per-file collapse, if still wanted, becomes a CodeView item-state concern
(`updateItem`) rather than server assigns — treat as optional polish, not core.

## Phase 0 — Spike & verify (no behavior change)

1. Confirm `Diffs.CodeView` is exported by the pinned `@pierre/diffs@1.1.22`
   (`assets/package.json`) and that its API has `setItems` / `addItems` /
   `updateItem` / `scrollTo`, the shared annotation props, sticky headers, and
   window-scroll virtualization. **If not present, bump `@pierre/diffs`** to the
   minimum version that ships `CodeView`, and re-check `Virtualizer` config
   (`overscrollSize`, `intersectionObserverMargin`, `resizeDebugging`).
2. Decide where **"mark file viewed"** lives once CodeView owns the (shadow-DOM)
   file headers — see Risks. Recommendation to validate: move the viewed
   pill + toggle into the file-tree sidebar rows, which already render per-file
   stats and have light-DOM `phx-click` surface.

## Phase 1 — CodeView renderer + hook (client)

- Add `code_view_renderer.js` and `hooks/code_view.js`; wire into `app.js`.
- Build `lineAnnotations` per item from threads grouped by file (reuse
  `threadsToAnnotations`).
- Theme observer + `diffStyle` handling, mirroring `vanilla_renderer.js`.

## Phase 2 — Server streaming (Changes view)

- `review_live.ex`: in the Changes-view branch (`@live_action == :changes ||
  !has_packet`, `review_live.ex:566-577`), render the single CodeView container
  instead of the `#diff-files` section. Keep the sidebar + file tree.
- Add the `{:stream_diffs, cursor}` loop and first-batch kickoff.
- Split `ReviewView.snapshot` into light metadata vs. per-batch diff fetch.
- Collapse `select_diff_style` to one `code_view:set_diff_style` push;
  `create_comment` + `{:thread_published, _}` to one `code_view:update_threads`
  push.
- Delete the changes-view expansion code paths and constants listed above.

## Phase 3 — Navigation & chrome re-homing

- File tree: `ChangesFileTree.scrollToPath` (`changes_file_tree.js:270-277`)
  currently does `getElementById("file-<id>").scrollIntoView()`. Off-screen
  CodeView items have no stable light-DOM node — route through a
  `reviews:scroll-to-anchor`-style custom event that the CodeView hook catches
  and answers with `codeView.scrollTo`.
- Open-threads sidebar: same scroll-to path.
- Mark-viewed: implement the Phase 0 decision.

## Phase 4 — Cleanup & tests

- Remove now-dead Changes-view code: per-file `DiffRenderer` mount in the
  Changes view, the `shouldVirtualize` thresholds (CodeView always virtualizes),
  `StickyHunkHeader` usage if the Changes view was its only consumer.
  Keep `diff_renderer.js` / `vanilla_renderer.js` / `hunk_card` — still used by
  the packet view.
- Rewrite `test/reviews_web/live/review_live_test.exs` Changes-view assertions:
  the diff body moves into shadow DOM, so assert on the `#changes-code-view`
  hook element + the `code_view:add_items` push payloads (per project test
  guidelines: test the hook contract, not diff internals). The 27-test suite
  must stay green.
- `mix precommit` (`compile --warnings-as-errors`, `format`, `test`).

## Risks

- **Mark-viewed / per-file chrome.** Today's mark-viewed is a light-DOM
  `phx-click` button in the card header (`packet_components.ex:928-967`).
  CodeView owns headers in shadow DOM. Resolution per Phase 0 — likely the file
  tree sidebar. This is the highest-uncertainty item; spike it first.
- **CodeView availability** in `1.1.22` — may force a version bump (Phase 0).
- **Window vs inner scroll.** CodeView must virtualize against the window so the
  page keeps one scrollbar and the sticky header keeps working; confirm in the
  Phase 0 spike (the current `VirtualizedFileDiff` path already does
  `virtualizer.setup(document, contentWrapper)`).
- **Test churn.** Several `review_live_test.exs` cases assert `#file-<id>`
  anchors and hunk toggle buttons; those move or disappear for the Changes view.

## Out of scope

- **AI Review Packet view** — keeps per-hunk `FileDiff` islands and section
  collapse. Both renderers coexist.
- **Syntax highlighting / Shiki swap.** `CodeView` is built on Shiki, so this
  work touches adjacent code, but turning highlighting *on* stays governed by
  the separate deferred plan (see `diff_renderer.js:8-18` and CLAUDE.md). The
  CodeView integration keeps the current plain-text presentation until that
  plan lands. `⚠ overlap` with the deferred Shiki swap.
- **Token-level commenting** — stays deferred; the `token_range` schema
  discriminator and `Anchoring.relocate/3` stub remain.
- **Scroll-position-aware batch reprioritization** — optional future
  enhancement, not v1.
- a11y items in `.plans/a11y-design-fixes.md` whose targets (`.rdr-*` line
  gutter, etc.) move into CodeView's shadow DOM for the Changes view become moot
  there; reconcile when that plan is next touched.

## Testing

- `mix test`, `mix compile --warnings-as-errors`, `mix format --check-formatted`.
- `reviews push` from a large checkout against the dev server; eyeball:
  first-paint latency, scrolling, all-files-expanded, batch fill-in, threads
  rendering + reply, mark-viewed, file-tree + open-threads navigation,
  split/unified toggle, patchset switch.
- Verify against a deliberately large review (many files, a 10k-line file) to
  confirm virtualization holds.

## Suggested landing order

1. **Phase 0 spike** — version check + mark-viewed decision. Cheap, unblocks the
   rest.
2. **Phases 1–2 together** — renderer/hook + server streaming; the Changes view
   is non-functional in between, so land as one reviewable unit.
3. **Phase 3** — navigation + mark-viewed.
4. **Phase 4** — cleanup + test rewrite; `mix precommit`.
