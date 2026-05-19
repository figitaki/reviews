# Structured Markdown review packets

This branch turns review packets into an authored guide through a diff: agents can write structured Markdown, the CLI validates complete hunk coverage, and reviewers get a narrative surface with inline diff context, section decisions, revision navigation, and a lighter large-diff path.

## Canonical packet storage and API shape
This section establishes the persisted contract: packets are stored as canonical JSON on patchsets, exposed as compact metadata, and wrapped in read helpers so the server does not need to understand Markdown at render time.

The packet starts as a nullable JSON field on patchsets, so older revisions and packetless pushes keep working while new revisions can carry authored context.

@hunk priv/repo/migrations/20260515004000_add_packet_to_patchsets.exs#1

The patchset schema exposes that JSON directly as part of the revision record.

@hunk lib/reviews/reviews/patchset.ex#1

Creation and update paths accept the packet alongside the existing diff metadata instead of introducing a separate packet resource.

@hunk lib/reviews/reviews/patchset.ex#2

Patchset creation now stores packet data at the same boundary where files and stats are already persisted.

@hunk lib/reviews/reviews.ex#1

File ingestion keeps enough parsed metadata around for later packet rendering and performance work.

@hunk lib/reviews/reviews.ex#2

The read path preloads the packet-bearing revision data so LiveView can choose between narrative and classic changes views.

@hunk lib/reviews/reviews.ex#3

Patchset updates follow the same packet-aware path, which keeps new revisions symmetric with initial review creation.

@hunk lib/reviews/reviews.ex#4

The server keeps packet handling close to patchset persistence, avoiding a second source of truth for review structure.

@hunk lib/reviews/reviews.ex#5

The context helpers now return enough information for callers to tell whether a packet exists without parsing the whole payload.

@hunk lib/reviews/reviews.ex#6

A small read-model layer normalizes packet JSON before templates touch it, which keeps rendering defensive while the prototype shape is still changing.

@hunk lib/reviews/review_packet.ex#1

Revision navigation is derived from patchsets, so packet revisions stay linear and easy to address by URL.

@hunk lib/reviews/review_navigation.ex#1

The review snapshot includes compact packet metadata for page headers and API clients.

@hunk lib/reviews/review_view.ex#1

Patchset stats are folded into the view model so the UI can summarize the selected revision without reparsing diffs.

@hunk lib/reviews/review_view.ex#2

Packet presence is exposed as lightweight metadata, which lets clients branch without downloading the full narrative first.

@hunk lib/reviews/review_view.ex#3

The view model keeps the classic diff data available even when the packet narrative is the default page.

@hunk lib/reviews/review_view.ex#4

The patchset API accepts an optional packet in the same request that uploads a new revision.

@hunk lib/reviews_web/controllers/api/patchset_controller.ex#1

Review creation accepts packet JSON without changing the existing diff-first API flow.

@hunk lib/reviews_web/controllers/api/review_controller.ex#1

The response includes just enough packet metadata for clients to confirm that the narrative was stored.

@hunk lib/reviews_web/controllers/api/review_controller.ex#2

Update handling keeps packet upload optional, so ordinary diff pushes still behave exactly as before.

@hunk lib/reviews_web/controllers/api/review_controller.ex#3

Controller tests and response shaping stay focused on JSON, leaving Markdown as a CLI authoring concern.

@hunk lib/reviews_web/controllers/api/review_controller.ex#4

## CLI authoring and packet validation
This section is the authoring path: structured Markdown is discovered or passed explicitly, converted into canonical JSON, validated against the exact diff, and uploaded through the existing push flow.

The CLI gets a packet flag on push, making authored review packets part of the normal local workflow.

@hunk cli/src/main.rs#1

The packet parser turns human-editable Markdown into canonical JSON and validates that every changed line is covered once.

@hunk cli/src/packet.rs#1

Push captures the raw diff before loading the packet so Markdown validation can happen locally before any network request.

@hunk cli/src/commands/push.rs#1

Packet discovery prefers the branch-specific Markdown draft when the user does not pass an explicit path.

@hunk cli/src/commands/push.rs#2

Explicit packet paths support both Markdown and JSON, which keeps manual testing and generated packets straightforward.

@hunk cli/src/commands/push.rs#3

Malformed or incomplete packet coverage fails early, before a review or patchset is created remotely.

@hunk cli/src/commands/push.rs#4

The parsed packet is threaded into review creation without disturbing the existing title, range, or update behavior.

@hunk cli/src/commands/push.rs#5

Patchset updates reuse the same packet loading path, so every new revision can carry its own narrative.

@hunk cli/src/commands/push.rs#6

The command keeps packet upload optional, preserving the lightweight diff-only workflow.

@hunk cli/src/commands/push.rs#7

The API client models packet JSON as optional request data.

@hunk cli/src/api.rs#1

Review creation serializes the packet only when one was provided.

@hunk cli/src/api.rs#2

Patchset creation follows the same optional packet contract.

@hunk cli/src/api.rs#3

Response decoding tracks whether the server stored a packet without requiring clients to render it.

@hunk cli/src/api.rs#4

The client request types stay compatible with servers and pushes that do not know about packets.

@hunk cli/src/api.rs#5

The API layer keeps Markdown out of the wire format; only canonical JSON crosses the boundary.

@hunk cli/src/api.rs#6

Configuration discovery gained enough branch awareness to find packet drafts in the local review workspace.

@hunk cli/src/config.rs#1

The default packet path is deterministic, which gives agents a stable place to draft the next revision.

@hunk cli/src/config.rs#2

Comment command changes are supporting cleanup around shared API/config behavior rather than part of packet rendering itself.

@hunk cli/src/commands/comment.rs#1

Login continues to use the shared client configuration that packet push now also depends on.

@hunk cli/src/commands/login.rs#1

Show output starts surfacing packet-related metadata so the CLI can confirm what was uploaded.

@hunk cli/src/commands/show.rs#1

The command keeps the display compact and still centered on the review URL and revision state.

@hunk cli/src/commands/show.rs#2

Packet metadata is treated as optional so older reviews remain readable from the CLI.

@hunk cli/src/commands/show.rs#3

The show path shares the same API response shape that push relies on.

@hunk cli/src/commands/show.rs#4

Integration coverage exercises packet upload through the CLI-facing path rather than only testing the parser in isolation.

@hunk cli/tests/integration.rs#1

## Narrative packet rendering
This section makes the packet the primary review experience: sections own the reading order, prose can be interleaved with inline diff views, and the classic changes route remains available when file grouping is useful.

The router splits the packet narrative and full changes view into separate URLs while keeping the same review slug.

@hunk lib/reviews_web/router.ex#1

The LiveView tracks whether the reviewer is on the narrative or classic changes route.

@hunk lib/reviews_web/live/review_live.ex#1

Selected revisions are loaded from query params so older packet versions can still be inspected.

@hunk lib/reviews_web/live/review_live.ex#2

Section expansion state lives in LiveView assigns instead of native details state, which avoids accidental resets from unrelated UI changes.

@hunk lib/reviews_web/live/review_live.ex#3

Diff display mode is synchronized across the main changes view and inline packet diffs.

@hunk lib/reviews_web/live/review_live.ex#4

Packet sections are prepared as the primary reading order before rendering.

@hunk lib/reviews_web/live/review_live.ex#5

Inline diff rows are resolved from authored packet references, letting prose break up the review by intent instead of by file.

@hunk lib/reviews_web/live/review_live.ex#6

Section decisions are loaded with enough revision context to distinguish current, inherited, invalidated, and pending state.

@hunk lib/reviews_web/live/review_live.ex#7

Reviewer actions can approve, deny, ignore, or clear a section decision without leaving the page.

@hunk lib/reviews_web/live/review_live.ex#8

The page header summarizes the selected revision with file counts, line stats, and estimated review time.

@hunk lib/reviews_web/live/review_live.ex#9

Classic changes rendering stays available behind the changes route for reviewers who need the raw file grouping.

@hunk lib/reviews_web/live/review_live.ex#10

Large file rendering is deferred until a collapsed file is opened, which keeps big reviews from mounting every diff island at once.

@hunk lib/reviews_web/live/review_live.ex#11

The LiveView now pushes enough structured data to the React diff island to render only the requested slice.

@hunk lib/reviews_web/live/review_live.ex#12

Packet components own the narrative UI: section headers, decisions, summaries, sticky prose, and inline diff slices.

@hunk lib/reviews_web/live/review_live/packet_components.ex#1

Revision navigation gives reviewers both direct version links and previous/next movement.

@hunk lib/reviews_web/live/review_live/revision_nav_components.ex#1

Diff components provide reusable wrappers for full-file diffs and packet slices so the two views stay visually consistent.

@hunk lib/reviews_web/live/review_live/diff_components.ex#1

The stylesheet starts defining the review packet layout and header rhythm.

@hunk assets/css/app.css#1

Section headers, estimates, line stats, and decision controls get the compact treatment used throughout the packet view.

@hunk assets/css/app.css#2

Decision buttons expand from icons to labeled pills on hover or selection.

@hunk assets/css/app.css#3

Packet prose and markdown rows get spacing that supports reading between diff slices.

@hunk assets/css/app.css#4

Inline diff containers keep dense code review content visually bounded without wrapping the whole packet in a card.

@hunk assets/css/app.css#5

The classic changes view gets collapsible file shells so large patchsets start cheap and navigable.

@hunk assets/css/app.css#6

Responsive rules keep packet controls and revision navigation usable on smaller screens.

@hunk assets/css/app.css#7

## Section decisions across revisions
This section adds reviewer state at the packet-section level, then uses best-effort matching so unchanged sections keep decisions while changed sections surface prior state as context.

Section decisions are persisted separately from packet content so reviewer state can survive across revisions.

@hunk priv/repo/migrations/20260515120000_create_packet_section_decisions.exs#1

The decision schema records reviewer, patchset, section identity, status, and invalidation context.

@hunk lib/reviews/reviews/packet_section_decision.ex#1

Decision matching carries approvals forward when a section still describes the same unchanged lines, and marks prior decisions as context when the covered code changes.

@hunk lib/reviews/packet_section_decisions.ex#1

## Large diff performance path
This section addresses large generated diffs: store per-file payloads once, avoid repeated full-diff scans, and defer expensive diff islands until a reviewer asks for a file.

Per-file diff payloads are stored so the app does not have to repeatedly scan one giant raw diff.

@hunk priv/repo/migrations/20260515233649_add_diff_payload_to_files.exs#1

File records now carry raw diff text and line stats needed for lazy rendering.

@hunk lib/reviews/reviews/file.ex#1

Backwards-compatible helpers allow older patchsets to fall back gracefully when per-file payloads are missing.

@hunk lib/reviews/reviews/file.ex#2

## Regression coverage
This section keeps the branch reviewable by testing each contract boundary: packet accessors, API storage, packet rendering, section decisions, lazy rendering, and CLI-visible metadata.

Packet tests lock down normalization so templates can depend on a stable read shape.

@hunk test/reviews/review_packet_test.exs#1

Patchset controller tests prove packet JSON can be stored on update without breaking diff-only uploads.

@hunk test/reviews_web/controllers/api/patchset_controller_test.exs#1

Review controller tests cover initial packet upload through the public API.

@hunk test/reviews_web/controllers/api/review_controller_test.exs#1

The API tests verify packet metadata appears in review responses.

@hunk test/reviews_web/controllers/api/review_controller_test.exs#2

Regression coverage keeps packetless reviews working as the default path.

@hunk test/reviews_web/controllers/api/review_controller_test.exs#3

The controller suite checks revision metadata and stats together with packet presence.

@hunk test/reviews_web/controllers/api/review_controller_test.exs#4

LiveView tests cover the packet narrative, revision navigation, section decisions, and collapsed rendering behavior.

@hunk test/reviews_web/live/review_live_test.exs#1

The latest UI tests guard the review-time summary, section summaries, and lazy diff behavior that make the demo feel usable.

@hunk test/reviews_web/live/review_live_test.exs#2
