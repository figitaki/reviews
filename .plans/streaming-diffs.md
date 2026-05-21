# Streaming diffs — all-expanded Changes view on one Pierre CodeView

Goal: make the classic Changes view (`/r/:slug`) render **every file diff
expanded by default**, fast, by (1) collapsing the per-hunk `@pierre/diffs`
islands into a single virtualized `CodeView`, and (2) streaming the raw diff
payloads to the client over the LiveView socket instead of inlining them in the
initial HTML.

## Decisions (locked)

- **Architecture:** Single `CodeView` per patchset. Pierre owns virtualization,
  sticky headers, and selection. "All expanded" becomes the native state.
- **Scope:** The **Changes view** gets the full CodeView migration. The **Review
  Packet view** gets a lighter treatment (Phase 5 — streaming + lazy render, no
  CodeView): `CodeViewItem` is `file | diff` only and cannot host the markdown
  prose interleaved between section hunks. The two diff-rendering paths coexist.
- **Layout:** The Changes view becomes a **full-height single-pane layout** —
  fixed header + sidebar, CodeView pane fills the viewport — so there is exactly
  one (real) scroll region and no nested-scroll wart.
- **Dependency:** Bump `@pierre/diffs` `1.1.22` → `1.2.1` (see spike findings —
  `CodeView` does not exist before `1.2.0`).

## Phase 0 — Spike findings (done)

Verified by installing the package and reading `dist/*.d.ts` for `1.1.22`
(pinned) and `1.2.1` (latest).

### `CodeView` requires a version bump

- `@pierre/diffs@1.1.22` does **not** export `CodeView`. Its multi-instance
  primitive is a shared `Virtualizer` + N `VirtualizedFileDiff`.
- `CodeView` landed in `1.2.0` (after `1.2.0-beta.0..6`); latest stable is
  **`1.2.1`**. → bump `assets/package.json` + `bun.lock`.
- The packet view's `vanilla_renderer.js` uses `FileDiff`, `Virtualizer`,
  `VirtualizedFileDiff`, `parsePatchFiles` — all still exported in `1.2.1`.
  Minor bump, low-risk, but the packet view must be regression-tested.

### `CodeView` API confirmed — it fits, and simplifies the plan

- **Self-contained virtualizer.** `new Diffs.CodeView(options?)` then
  `codeView.setup(root)`. No separate `Virtualizer` to construct/wire — CodeView
  manages its `VirtualizedFileDiff` child instances and render range itself.
- **Streaming methods** are exactly what batched server push needs:
  `addItems(items)` (documented append-only fast path — measures new items
  immediately, single render), `addItem`, `setItems`, `updateItem`,
  `updateItemId`, `getItem`, `reset`.
- **`scrollTo(target)`** supports `{type:'item'|'line'|'range'|'position', id,
  align, behavior}` — covers file-tree and open-threads navigation.
- **`subscribeToScroll(listener)`** exposes scroll position — enables optional
  scroll-aware batch prioritization later.
- **Item shape** — `CodeViewDiffItem = { id, type:'diff', fileDiff:
  FileDiffMetadata, annotations?: DiffLineAnnotation[], version?, collapsed? }`.
  - `fileDiff` is produced by `parsePatchFiles(rawDiff)` — the same call
    `vanilla_renderer.js` already makes. So **the server streams raw git-diff
    text and the hook parses it client-side**; no raw diff in socket assigns,
    no `data-raw-diff` attribute.
  - `annotations: DiffLineAnnotation[]` (`{side, lineNumber, metadata}`) already
    matches the output of the existing `threadsToAnnotations` (`schemas.js`).
  - `collapsed?: boolean` is **per-item state** — per-file collapse is native to
    CodeView (`updateItem` with `collapsed`); "all expanded by default" = simply
    never setting it. No server-side expansion bookkeeping at all.
  - `version?: number` — bump it when an item's annotations change so CodeView
    re-renders just that item.

### Mark-viewed risk — resolved

`CodeViewOptions` exposes per-item header render slots — `renderCustomHeader`,
`renderHeaderPrefix`, `renderHeaderMetadata` — plus `renderGutterUtility` /
`onGutterUtilityClick`, and `stickyHeaders?: boolean`. The "mark file viewed"
control and viewed-state pill render **inside the CodeView item header** via
`renderHeaderMetadata`, wired to `pushEvent`. No relocation to the sidebar is
needed, and the custom `StickyHunkHeader` hook is dropped for the Changes view.

### New finding — CodeView is an inner-scroll container

`CodeView.setup(root: HTMLElement)` virtualizes against **`root`'s own scroll**,
not the window (the standalone `Virtualizer` accepted `Document`; `CodeView`
does not). The Changes view therefore adopts a **full-height single-pane
layout**: fixed header + sidebar, and the CodeView `root` fills the remaining
viewport (`calc(100dvh - header)`). The page itself does not scroll, so there is
exactly one real scroll region — a small diff just does not scroll, no
nested-scrollbar wart. Sticky file headers inside the pane come from
`stickyHeaders: true`. See Risks for the layout rework.

### Other confirmed details

- `itemMetrics?: Partial<VirtualFileMetrics>` — height estimates
  (`lineHeight`, `diffHeaderHeight`, `spacing`, ...); tune in the renderer.
- `layout?: {paddingTop, paddingBottom, gap}` — inter-item spacing.
- Pass-through diff options include `diffStyle`, `theme`, `unsafeCSS`,
  `expandUnchanged`, `collapsedContextThreshold` — split/unified toggle and the
  typography `unsafeCSS` carry over via one `setOptions` call.
- Constructor takes an optional `workerManager` — **omit it**; single-threaded
  highlighter stays the v1 target per CLAUDE.md.

## Why the current design can't just "expand all"

The Changes view (`DiffComponents.diff_shell`, `diff_components.ex:90-117`)
renders one `PacketComponents.hunk_card` per file. Each card:

- Renders the Pierre island **only when expanded** —
  `<div :if={@expanded?} phx-hook="DiffRenderer" ...>` (`packet_components.ex:971`).
- Inlines the file's entire raw diff as a `data-raw-diff` HTML attribute
  (`packet_components.ex:982`).
- Mounts its own `Diffs.FileDiff` / `Diffs.VirtualizedFileDiff` with its own
  `Virtualizer` (`vanilla_renderer.js`).

So expanding everything today means the full raw diff of every file in the
initial HTML payload, plus N island mounts each with its own virtualizer. That
cliff is why `expanded_*` MapSets and the `@changes_auto_open_line_limit` budget
(`review_live.ex:35`) exist. One `CodeView` only renders visible lines, so "all
expanded" is free and the budget logic goes away.

In the Changes view a "card" is already **file-level** — `hunk_card` is fed
`ReviewHunks.combine_consecutive(hunks)` (`diff_components.ex:129`). So one
`CodeViewDiffItem` == one file maps cleanly; no per-hunk granularity to keep.

## Target architecture

### Client: one CodeView

- New `assets/js/diff_renderer/code_view_renderer.js` — wraps a single
  `Diffs.CodeView` (self-contained; no separate `Virtualizer`). On `setup` it is
  given the height-bounded `root` container element.
- New hook `assets/js/hooks/code_view.js` on a single
  `<div id="changes-code-view" phx-hook="CodeView" phx-update="ignore">`. It
  owns the CodeView instance and handles server pushes:
  - `code_view:add_items` → parse each raw diff with `parsePatchFiles`, build
    `CodeViewDiffItem`s, `codeView.addItems(items)` (streaming batches).
  - `code_view:update_threads` → recompute one item's `annotations`, bump
    `version`, `codeView.updateItem(...)`.
  - `code_view:set_diff_style` → `codeView.setOptions({diffStyle})` (one event,
    not one-per-file).
  - `code_view:scroll_to` → `codeView.scrollTo({type:'item', id})`.
  - `code_view:reset` → `codeView.reset()` on patchset switch.
- Item headers: `renderHeaderMetadata` renders the mark-viewed control + viewed
  pill, wired to `pushEvent`. `stickyHeaders: true`.
- Comment composer: `renderAnnotation` + `onLineNumberClick` / `onTokenClick`
  drive the composer; reuse `annotation_ui.js`, `lib/translate.js`,
  `schemas.js`. Opening the composer = `updateItem` on the affected item with a
  bumped `version` and an extra composer annotation (per-item update, vs today's
  full island re-render).
- Register `CodeView` in `app.js`.

### Server: stream the diffs over the socket

The stateful socket pushes diff payloads progressively after first paint
(`stream/3` DOM streams do not apply — the diff body lives in a
`phx-update="ignore"` island).

- `mount/3` (connected) renders the page shell + the **empty** CodeView
  container, and assigns only **light file metadata** (path, status, +/−
  counts, viewed state) — no raw diffs in the render tree.
- Streaming loop: `handle_info({:stream_diffs, cursor}, socket)` pops the next
  batch of files, reads each `File.raw_diff` (column already exists — `file.ex`),
  `push_event`s `code_view:add_items` with raw diff text, then reschedules
  itself with `send(self(), ...)` so the LiveView yields between batches.
- Kick the first batch off from the connected `mount/3` so the top of the page
  fills in one round-trip.
- On patchset switch / `{:patchset_pushed, n}`: push `code_view:reset` and
  restart the loop.

**Intelligent ordering.** Stream in file-tree order so the top of the viewport
fills first; **first batch small** (≈6 files or ≈400 changed lines, whichever
first) for fast first paint, then larger batches (≈30 files / ≈2000 lines).
Constants live next to the existing `review_live.ex` budget constants. Optional
later: use `subscribeToScroll` to report position and reprioritize remaining
batches — **not** v1.

**Memory win.** Raw diffs leave socket assigns: read per-batch from the `files`
rows, pushed once, then owned by the client's CodeView. `ReviewView.snapshot` /
`file_diff_meta` (`review_view.ex:114-133`) gets a "light" path that skips
loading `raw_diff` into `file_diffs`.

### Expanded-by-default

CodeView virtualizes, so the Changes view drops `expanded_file_ids`, the
changes-view use of `expanded_hunk_ids`, `@changes_auto_open_line_limit`, and
the `default_expanded_changes_hunk_ids` / `apply_changes_default_expansion?` /
`maybe_apply_changes_default_expansion` / `changes_default_expanded_patchset_ids`
machinery (`review_live.ex:1023-1057`), plus the `toggle_file_diff` /
`toggle_hunk_diff` handlers for the Changes view. Per-file collapse, if wanted,
is a `collapsed` field on the item — client-side, no server assigns. (The packet
view keeps `expanded_section_ids` / `expanded_hunk_ids` and `@section_*`.)

## Phase 1 — Dependency bump + CodeView renderer/hook (client)

- Bump `@pierre/diffs` to `1.2.1` (`assets/package.json`, `bun.lock`);
  smoke-test the packet view (`vanilla_renderer.js`) for regressions.
- Add `code_view_renderer.js` + `hooks/code_view.js`; wire into `app.js`.
- Build `annotations` per item via `threadsToAnnotations`; theme observer and
  `diffStyle` handling mirroring `vanilla_renderer.js`.

## Phase 2 — Server streaming (Changes view)

- `review_live.ex`: in the Changes-view branch (`review_live.ex:566-577`),
  render the single CodeView container instead of the `#diff-files` section.
  Keep the sidebar + file tree. Restructure the Changes view into a full-height
  single-pane layout (fixed header + sidebar, CodeView pane fills the viewport).
- Add the `{:stream_diffs, cursor}` loop and first-batch kickoff.
- Split `ReviewView.snapshot` into light metadata vs. per-batch diff fetch.
- Collapse `select_diff_style` → one `code_view:set_diff_style` push;
  `create_comment` + `{:thread_published, _}` → one `code_view:update_threads`.
- Delete the changes-view expansion code paths and constants listed above.

## Phase 3 — Navigation & chrome

- File tree: `ChangesFileTree.scrollToPath` (`changes_file_tree.js:270-277`)
  currently does `getElementById("file-<id>").scrollIntoView()`. Off-screen
  CodeView items have no light-DOM node — route through a custom event the
  CodeView hook answers with `codeView.scrollTo`.
- Open-threads sidebar: same scroll-to path.
- Mark-viewed: `renderHeaderMetadata` control + `pushEvent` (per spike).

## Phase 4 — Cleanup & tests

- Remove dead Changes-view code: per-file `DiffRenderer` mount in the Changes
  view, the `shouldVirtualize` thresholds, `StickyHunkHeader` usage if the
  Changes view was its only consumer. Keep `diff_renderer.js` /
  `vanilla_renderer.js` / `hunk_card` — still used by the packet view.
- Rewrite `test/reviews_web/live/review_live_test.exs` Changes-view assertions:
  the diff body moves into shadow DOM, so assert on `#changes-code-view` + the
  `code_view:add_items` push payloads (test the hook contract, not diff
  internals). The 27-test suite must stay green.
- `mix precommit`.

## Phase 5 — Packet-view streaming + lazy render (beefy sections)

CodeView does not fit the packet view — `CodeViewItem` is `file | diff` only and
cannot host the markdown prose interleaved between hunks, and that interleaving
is the packet's purpose. The packet view keeps its per-hunk `FileDiff` islands
but takes the two transferable benefits — no CodeView, no inner scroll:

- **Stream the diffs off the socket.** Today every expanded hunk inlines its
  full `data-raw-diff` in the section-body HTML (`packet_components.ex:982`) —
  opening a beefy section ships all of it in one LiveView payload. Instead,
  render the hunk-card shells and stream the raw diff text into the islands in
  batches via `push_event` once a section opens. Reuses the Phase 2 loop.
- **Viewport-gated rendering.** Defer the heavy Pierre `render()` until a hunk
  shell nears the viewport (IntersectionObserver in the `DiffRenderer` hook),
  instead of mounting every island the instant a section opens.
- **Relax the auto-open budgets.** With rendering deferred and diffs streamed,
  `@section_expand_all_line_limit`, `@section_expand_all_file_limit`,
  `@section_auto_open_loc_budget` and friends (`review_live.ex:29-35`) can be
  loosened or dropped — beefy sections can expand-all by default.

Lower blast radius than the CodeView migration; depends on the Phase 2 streaming
loop. Land after Phases 1–4.

## Risks

- **Full-height layout rework.** The Changes view becomes fixed header + sidebar
  + a viewport-filling CodeView pane (one real scroll region). Touches `app.css`
  (`.rev-shell`, `.review-hunk-list`) and forces a call on the review
  header/description — compact fixed chrome, or it scrolls away above the pane.
  Medium effort, contained to the Changes view.
- **Packet view regression** from the `1.2.1` bump — exercise it after Phase 1.
- **Composer per-item updates.** Opening/closing the comment composer is now an
  `updateItem` + `version` bump rather than a full island re-render; verify
  composer open/cancel/save and thread refresh.
- **Test churn.** `review_live_test.exs` cases asserting `#file-<id>` anchors
  and hunk toggle buttons move or disappear for the Changes view.

## Out of scope

- **Full CodeView in the packet view** — structurally impossible (`CodeViewItem`
  is `file | diff`; cannot host section prose). The packet view keeps its
  per-hunk `FileDiff` islands and gets the lighter Phase 5 treatment instead.
- **Syntax highlighting / Shiki swap.** `CodeView` is built on Shiki, but
  turning highlighting *on* stays governed by the separate deferred plan (see
  `diff_renderer.js:8-18` and CLAUDE.md). The CodeView integration keeps the
  current plain-text presentation until that plan lands. `⚠ overlap` with the
  deferred Shiki swap.
- **Token-level commenting** — stays deferred; the `token_range` schema
  discriminator and `Anchoring.relocate/3` stub remain.
- **Scroll-position-aware batch reprioritization** — optional future work.
- a11y items in `.plans/a11y-design-fixes.md` whose targets (`.rdr-*` gutter,
  etc.) move into CodeView's shadow DOM for the Changes view become moot there;
  reconcile when that plan is next touched.

## Testing

- `mix test`, `mix compile --warnings-as-errors`, `mix format --check-formatted`.
- `reviews push` from a large checkout against the dev server; eyeball:
  first-paint latency, inner-scroll, all-files-expanded, batch fill-in, threads
  rendering + reply, mark-viewed, file-tree + open-threads navigation,
  split/unified toggle, patchset switch.
- Regression-check the packet view after the `1.2.1` bump.
- Verify against a deliberately large review (many files, a 10k-line file).

## Suggested landing order

1. ~~Phase 0 spike~~ — done (this section).
2. **Phases 1–2 together** — dependency bump + renderer/hook + server streaming;
   the Changes view is non-functional in between, so land as one reviewable
   unit.
3. **Phase 3** — navigation + mark-viewed.
4. **Phase 4** — cleanup + test rewrite; `mix precommit`.
5. **Phase 5** — packet-view streaming + lazy render, after Phases 1–4 land.
