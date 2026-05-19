# Shared Hunk Laziness + Viewed State

This packet organizes the hunk-level review work by the way the feature is wired: durable state first, then read-model plumbing, LiveView orchestration, shared rendering, styling, and tests. The main thing to keep in mind while reviewing is that "open/collapsed" remains ephemeral UI state, while "viewed" is now persisted per reviewer and reused by both packet and Changes views.

## Persisted hunk progress and shared hunk parsing

This section introduces the durable hunk-view state and the hunk read model that both UI surfaces consume. Review this first because the rest of the UI assumes these helpers define the canonical hunk identity, fingerprint, sliced display payload, and viewed-state lookup.

### Technical overview and tradeoffs

The persisted model is intentionally narrow: it stores the current review, reviewer, patchset, file path, canonical row ref, hunk fingerprint, hunk index, optional line range, and optional packet-section metadata. The unique key uses `review_id`, `author_id`, `file_path`, `row_ref`, and `hunk_fingerprint`, which means viewed state carries only when the same underlying hunk identity and content are still present; changed hunks naturally require review again.

`Reviews.ReviewHunks` centralizes raw diff parsing so packet sections and `/changes` do not each slice strings or count changed lines independently. The tradeoff is that packet line-slices now share the full hunk fingerprint and viewed identity with the Changes view, so a packet slice and its full Changes hunk intentionally mark the same review unit as viewed.

The migration creates the durable progress table and indexes it for per-reviewer lookups.
@hunk priv/repo/migrations/20260518190000_create_packet_hunk_views.exs#1

The schema mirrors the migration and keeps validation focused on the identity fields needed for reliable carry-forward.
@hunk lib/reviews/reviews/packet_hunk_view.ex#1

The context owns listing, upserting, clearing, and comparing viewed hunk keys so LiveView code does not need to know the table shape.
@hunk lib/reviews/packet_hunk_views.ex#1

The shared hunk read model parses file diffs once, builds stable row refs and fingerprints, slices packet display hunks, and annotates entries with viewed state.
@hunk lib/reviews/review_hunks.ex#1

## Review snapshot integration

This section threads hunk data into the existing review snapshot. It is deliberately placed in the read model rather than directly in components so packet and Changes rendering receive the same precomputed hunk map.

### Technical overview and tradeoffs

`ReviewView.snapshot/3` now loads the current user's hunk views, computes file payloads once, and derives `hunks_by_path` from those file payloads. That keeps DB access and diff parsing near the rest of the review read model, while preserving anonymous behavior by returning an empty view list when there is no viewer.

These aliases pull hunk-view persistence and shared parsing into the snapshot layer.
@hunk lib/reviews/review_view.ex#1
@hunk lib/reviews/review_view.ex#2

The snapshot type and construction now document hunk metadata, load persisted viewed rows, and return the shared hunk map.
@hunk lib/reviews/review_view.ex#3

## LiveView state and events

This section is the server-side interaction layer for opening hunks and marking them viewed. The important behavior is that expansion is only a LiveView assign, while viewed/unviewed changes go through the new persistence context and refresh the snapshot.

### Technical overview and tradeoffs

The LiveView now tracks `expanded_hunk_ids` alongside expanded files and sections. Diff-style broadcasts were narrowed to currently mounted hunk islands, avoiding the previous pattern where packet file membership caused style updates to target diff surfaces that were not actually rendered.

The mark viewed/unviewed handlers parse only the fields emitted by hunk cards, persist through `PacketHunkViews`, and refresh the snapshot. This costs a refresh after every viewed-state toggle, but it keeps packet progress, Changes cards, and cross-view state consistent without introducing a separate client-side store.

The LiveView imports hunk-view persistence as the only new server-side dependency for event handling.
@hunk lib/reviews_web/live/review_live.ex#1

Mount initializes hunk expansion separately from file and section expansion.
@hunk lib/reviews_web/live/review_live.ex#2

Diff-style changes now calculate mounted hunk paths instead of broadcasting to every packet-related file.
@hunk lib/reviews_web/live/review_live.ex#3

These handlers add session-only hunk open/collapse and explicit viewed/unviewed actions.
@hunk lib/reviews_web/live/review_live.ex#4

Packet header effort calculation now receives shared hunk metadata, so progress and estimates come from the same parsed entries as the renderer.
@hunk lib/reviews_web/live/review_live.ex#5

Packet rendering receives shared hunk data from the snapshot.
@hunk lib/reviews_web/live/review_live.ex#6

The Changes route receives both hunk expansion and hunk metadata, making it use the same interaction primitive as packets.
@hunk lib/reviews_web/live/review_live.ex#7

Viewed-state persistence is centralized behind parameter parsing and action-specific helpers.
@hunk lib/reviews_web/live/review_live.ex#8

Patchset changes reset hunk expansion just like file and section expansion.
@hunk lib/reviews_web/live/review_live.ex#9

Snapshots assign hunk metadata and persisted view rows for component consumption.
@hunk lib/reviews_web/live/review_live.ex#10

Mounted diff path discovery replaces packet-wide targeting with a lookup over actually opened hunk ids.
@hunk lib/reviews_web/live/review_live.ex#11

## Shared hunk rendering in packet and Changes views

This section replaces eager diff rendering with a shared hunk card. Review this for the main user-facing behavior: packet rows and Changes files now both render lightweight cards first, then mount `DiffRenderer` only for opened hunks.

### Technical overview and tradeoffs

The packet component now delegates hunk lookup and display slicing to `ReviewHunks`, removing the old local raw-diff slicing helpers. The shared `hunk_card/1` component carries controls for opening, marking viewed, showing viewed state, and rendering the React island only when opened.

The Changes component reuses the same `PacketComponents.hunk_card/1` inside an opened file. This creates a dependency from the Changes component back to the packet component module, which is a pragmatic reuse choice for now; if the component grows further, it would be reasonable to move the card into a neutral `HunkComponents` module.

The packet component imports the shared hunk parser so packet rows can resolve canonical hunk entries.
@hunk lib/reviews_web/live/review_live/packet_components.ex#1

Packet components now require the shared hunk map and expanded hunk set.
@hunk lib/reviews_web/live/review_live/packet_components.ex#2

Section summaries now show viewed progress in the same compact area as estimates.
@hunk lib/reviews_web/live/review_live/packet_components.ex#3

Packet rows receive the shared hunk data and section title needed by the card and persisted metadata.
@hunk lib/reviews_web/live/review_live/packet_components.ex#4

Header effort calculation accepts the hunk map so section stats and progress can be derived without local diff parsing.
@hunk lib/reviews_web/live/review_live/packet_components.ex#5
@hunk lib/reviews_web/live/review_live/packet_components.ex#6
@hunk lib/reviews_web/live/review_live/packet_components.ex#7

Section estimates now use shared hunk entries and count viewed hunks while preserving existing time estimates.
@hunk lib/reviews_web/live/review_live/packet_components.ex#8

The old packet-local changed-line counter is removed because the shared hunk model now owns that work.
@hunk lib/reviews_web/live/review_live/packet_components.ex#9

Packet rows declare the hunk data they need and carry section context into the shared card.
@hunk lib/reviews_web/live/review_live/packet_components.ex#10

The eager inline diff is replaced by a hunk card that can remain collapsed until the reviewer asks for the diff.
@hunk lib/reviews_web/live/review_live/packet_components.ex#11

The shared hunk card replaces packet-local slicing helpers and owns both the collapsed summary and lazy-mounted diff body.
@hunk lib/reviews_web/live/review_live/packet_components.ex#12

Packet row ids are decoded only to attach optional section metadata to viewed hunk rows.
@hunk lib/reviews_web/live/review_live/packet_components.ex#13

Changes view imports the shared hunk card rather than keeping a separate full-file renderer.
@hunk lib/reviews_web/live/review_live/diff_components.ex#1

Changes view declares hunk metadata and expansion state so opened files can show hunk cards.
@hunk lib/reviews_web/live/review_live/diff_components.ex#2

Opened files now show a list of hunk cards instead of immediately mounting a full-file `DiffRenderer`.
@hunk lib/reviews_web/live/review_live/diff_components.ex#3

The old per-file JSON helpers are removed because the shared card owns `DiffRenderer` data attributes.
@hunk lib/reviews_web/live/review_live/diff_components.ex#4

## Hunk card styling

This section adds the visual treatment for hunk cards. The CSS is intentionally small and uses existing review design tokens so the new primitive fits both packet sections and Changes files.

### Technical overview and tradeoffs

The styling keeps cards dense: hunk identity, line range, stats, viewed state, and actions fit in one summary row. The open state only rotates the existing collapse icon and reveals the diff body; no animation-heavy behavior was added because the primary goal is performance and predictable layout on large diffs.

The hunk list and card styles create a reusable collapsed surface for both packet and Changes contexts.
@hunk assets/css/app.css#1

## Regression coverage

This section updates the LiveView tests to lock the new two-step rendering behavior and shared viewed state. The tests are deliberately outcome-focused: they assert when `DiffRenderer` should and should not exist, and they verify that packet and Changes views agree on viewed state.

### Technical overview and tradeoffs

The existing tests now open a file or packet section and verify that a hunk card appears before any diff island mounts. The shared-state test marks a hunk viewed in the packet, checks that Changes reflects it, clears it from Changes, and then verifies packet progress resets.

The anonymous file-tree smoke test now requires a second hunk click before `DiffRenderer` appears.
@hunk test/reviews_web/live/review_live_test.exs#1

The packet rendering test now verifies hunk-card laziness before opening the packet hunk.
@hunk test/reviews_web/live/review_live_test.exs#2

The Changes route test now verifies file expansion and hunk expansion as separate steps.
@hunk test/reviews_web/live/review_live_test.exs#3

The signed-in reviewer test covers shared viewed state across packet and Changes views, including unviewing.
@hunk test/reviews_web/live/review_live_test.exs#4
