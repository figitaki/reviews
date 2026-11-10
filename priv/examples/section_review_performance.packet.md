# Structured Markdown review packets

**Review the intent, then the code.** This demo is a real review of the change that introduced structured Markdown packets to Reviews. The bundled diff is a historical snapshot, not a claim that every implementation detail still matches today's application.

A packet is an *authored reading order* for a diff. Instead of making you infer the story from an alphabetical file list, it puts the explanation beside the changes it describes.

1. **Choose a section** in the guide map, or select **Begin review** below.
2. Read the context, open the inline diffs, and leave a line comment when something needs discussion.
3. Sign in to record a section decision: **Approve**, **Request changes**, or **Skip**.

![Review interaction flow between the user, agent, and Reviews service: request a change, share a review link, give feedback, and review the agent's next revision.](/images/demo-packet-flow.svg)

**Three parties, one feedback loop.** The agent prepares the change and its packet; Reviews hosts the diff, comments, and decisions; you review the work and ask for revisions. The agent reads that feedback and uploads the next patchset—Reviews does not automatically push feedback to the agent or merge the change.

On a narrow screen, scroll the diagram sideways or [open it full-size](/images/demo-packet-flow.svg). It is rendered from bundled Mermaid source, without an external image service.

Prefer a file-by-file pass? Switch to **Diff** in the toolbar. For the authoring workflow, see the [Reviews README](https://github.com/figitaki/reviews#readme).

## Canonical packet storage and API shape
**The storage boundary is JSON, not Markdown.** Authors work in Markdown; each patchset stores the parsed packet alongside its diff. This keeps the reading guide and the code it explains on the same revision.

As you read, check three compatibility guarantees:

- **Optional packets:** existing diff-only reviews must still work.
- **One source of truth:** packet content belongs to the patchset, not a separate document that can drift away from it.
- **Small responses:** clients can discover packet metadata without first rendering the complete narrative.

*Focus your review on the write/read symmetry.* Initial creation and later revisions should accept and expose the same packet shape.

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
**Catch incomplete coverage before upload.** The CLI reads the packet, resolves its hunk references against the exact diff, and sends canonical JSON through the existing push flow.

The intended authoring loop is:

1. Draft a packet with `##` sections and `@hunk path#number` references.
2. Pass it explicitly with `--packet`, or use the branch-specific discovery path.
3. Fix malformed references or uncovered changes *locally*, before creating a remote revision.

```sh
reviews push --packet path/to/packet.md
reviews push --update REVIEW_SLUG --packet path/to/packet.md
```

**Review question:** do initial uploads and `--update` share the same validation, rather than allowing a later revision to bypass it?

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
**The guide is the reading order; the diff is the evidence.** Prose and inline hunks alternate so a reviewer can evaluate an argument without hunting through unrelated files.

- **Guide:** follow the author's sections and review the relevant slices in context.
- **Diff:** inspect the same revision grouped by file.
- **Revisions:** return to an earlier patchset without losing which code the packet describes.

> A good packet explains *why a change belongs here*. It should not just translate each changed line into English.

Pay particular attention to **shared state**: changing diff style, selecting a revision, and opening a large file should behave consistently in both views.

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

The LiveView pushes structured data to the diff island so it can render only the requested slice. This historical patch predates the current vanilla renderer.

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
**An approval is about code, not just a heading.** Decisions belong to a reviewer, a section, and a patchset. Later revisions can use prior decisions as context, but changed code must not silently look approved.

- **Unchanged section:** carry the decision forward when the matching logic establishes that the covered lines are unchanged.
- **Changed section:** show the earlier decision as *outdated context*, not a fresh approval.
- **No match:** leave the new section pending.

The key question is asymmetric: changing the explanation alone and changing the covered code are not necessarily the same event. Read the matching rules before trusting a carried-forward badge.

Section decisions are persisted separately from packet content so reviewer state can survive across revisions.

@hunk priv/repo/migrations/20260515120000_create_packet_section_decisions.exs#1

The decision schema records reviewer, patchset, section identity, status, and invalidation context.

@hunk lib/reviews/reviews/packet_section_decision.ex#1

Decision matching carries approvals forward when a section still describes the same unchanged lines, and marks prior decisions as context when the covered code changes.

@hunk lib/reviews/packet_section_decisions.ex#1

## Large diff performance path
**Do less work before the reviewer asks for it.** A generated diff can be large even when a reviewer only needs one file or one section.

This change takes two complementary steps:

1. Store per-file payloads and line counts instead of repeatedly scanning the entire raw diff.
2. Defer expensive diff rendering until the reviewer opens the relevant file.

*Compatibility matters as much as speed:* older patchsets without stored per-file payloads still need a working fallback. These hunks establish that data path; they are not a benchmark.

Per-file diff payloads are stored so the app does not have to repeatedly scan one giant raw diff.

@hunk priv/repo/migrations/20260515233649_add_diff_payload_to_files.exs#1

File records now carry raw diff text and line stats needed for lazy rendering.

@hunk lib/reviews/reviews/file.ex#1

Backwards-compatible helpers allow older patchsets to fall back gracefully when per-file payloads are missing.

@hunk lib/reviews/reviews/file.ex#2

## Regression coverage
**Test the boundaries a reviewer relies on.** The suite connects the authoring format to persistence, API responses, and the page the reviewer actually reads.

- Packet accessors normalize the stored shape.
- API tests cover both packet-bearing and packetless uploads.
- LiveView tests exercise narrative rendering, revisions, decisions, and deferred diffs.
- CLI integration tests check the upload path, not just the parser in isolation.

When deciding whether these tests are sufficient, ask: *which plausible regression would make the wrong code look reviewed?* That is a stronger bar than checking that the page mounts.

After this section, try switching back to **Overview** from the guide map, or explore the source in the [Reviews repository](https://github.com/figitaki/reviews).

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
