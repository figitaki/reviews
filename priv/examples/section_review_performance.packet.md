# Section review performance and packet UX

This revision makes review packets feel like the primary review surface: section decisions update immediately, reviewed sections collapse out of the way, mobile controls stay compact, preview auth failures are easier to diagnose, and the broader packet system remains organized around narrative sections instead of raw file order.

## Packet storage and API contract
This section is the persisted JSON contract: packet data rides along with patchsets, and the API exposes enough metadata for clients without making the server parse Markdown.

Navigation helpers turn patchsets into revision metadata for direct links and previous/next controls.
@hunk lib/reviews/review_navigation.ex#1

The packet read model normalizes JSON into a safe shape for templates and downstream helpers.
@hunk lib/reviews/review_packet.ex#1

The review snapshot gathers packet metadata, diff stats, threads, drafts, and decisions into the LiveView/API read model.
@hunk lib/reviews/review_view.ex#1

The review snapshot gathers packet metadata, diff stats, threads, drafts, and decisions into the LiveView/API read model.
@hunk lib/reviews/review_view.ex#2

The review snapshot gathers packet metadata, diff stats, threads, drafts, and decisions into the LiveView/API read model.
@hunk lib/reviews/review_view.ex#3

The review snapshot gathers packet metadata, diff stats, threads, drafts, and decisions into the LiveView/API read model.
@hunk lib/reviews/review_view.ex#4

This change participates in the packet review flow and should be read as part of the surrounding section.
@hunk lib/reviews/reviews.ex#1

This change participates in the packet review flow and should be read as part of the surrounding section.
@hunk lib/reviews/reviews.ex#2

This change participates in the packet review flow and should be read as part of the surrounding section.
@hunk lib/reviews/reviews.ex#3

This change participates in the packet review flow and should be read as part of the surrounding section.
@hunk lib/reviews/reviews.ex#4

This change participates in the packet review flow and should be read as part of the surrounding section.
@hunk lib/reviews/reviews.ex#5

This change participates in the packet review flow and should be read as part of the surrounding section.
@hunk lib/reviews/reviews.ex#6

This change participates in the packet review flow and should be read as part of the surrounding section.
@hunk lib/reviews/reviews/patchset.ex#1

This change participates in the packet review flow and should be read as part of the surrounding section.
@hunk lib/reviews/reviews/patchset.ex#2

The API controller accepts optional packet JSON while preserving the existing diff upload contract.
@hunk lib/reviews_web/controllers/api/patchset_controller.ex#1

The API controller accepts optional packet JSON while preserving the existing diff upload contract.
@hunk lib/reviews_web/controllers/api/review_controller.ex#1

The API controller accepts optional packet JSON while preserving the existing diff upload contract.
@hunk lib/reviews_web/controllers/api/review_controller.ex#2

The API controller accepts optional packet JSON while preserving the existing diff upload contract.
@hunk lib/reviews_web/controllers/api/review_controller.ex#3

The API controller accepts optional packet JSON while preserving the existing diff upload contract.
@hunk lib/reviews_web/controllers/api/review_controller.ex#4

The migration adds the storage needed for this part of the packet review model while preserving existing review data.
@hunk priv/repo/migrations/20260515004000_add_packet_to_patchsets.exs#1

## CLI packet authoring and validation
This section is the agent-facing authoring path: the CLI discovers or accepts packet files, validates coverage against the diff, and uploads canonical JSON.

The CLI API types model packet JSON as optional request data.
@hunk cli/src/api.rs#1

Initial review creation serializes packet data only when one was provided.
@hunk cli/src/api.rs#2

Patchset creation follows the same optional packet contract.
@hunk cli/src/api.rs#3

Responses expose packet presence without making clients fetch or render the whole packet.
@hunk cli/src/api.rs#4

The request shape remains compatible with packetless pushes.
@hunk cli/src/api.rs#5

Markdown stays out of the wire format; only canonical JSON crosses the API boundary.
@hunk cli/src/api.rs#6

This CLI change supports the packet-aware push flow while keeping the existing command behavior recognizable.
@hunk cli/src/commands/comment.rs#1

This CLI change supports the packet-aware push flow while keeping the existing command behavior recognizable.
@hunk cli/src/commands/login.rs#1

Push captures the raw diff before packet loading so validation can happen before any network request.
@hunk cli/src/commands/push.rs#1

Default packet discovery checks the branch-specific Markdown draft when no explicit packet is passed.
@hunk cli/src/commands/push.rs#2

Explicit packet paths support both Markdown and JSON authoring workflows.
@hunk cli/src/commands/push.rs#3

Malformed packets stop the push locally instead of creating a broken remote review.
@hunk cli/src/commands/push.rs#4

Parsed packet JSON is threaded into initial review creation alongside the existing diff payload.
@hunk cli/src/commands/push.rs#5

Patchset updates reuse the same packet path so every revision can carry a fresh narrative.
@hunk cli/src/commands/push.rs#6

The push command keeps packet upload optional for quick diff-only reviews.
@hunk cli/src/commands/push.rs#7

This CLI change supports the packet-aware push flow while keeping the existing command behavior recognizable.
@hunk cli/src/commands/show.rs#1

This CLI change supports the packet-aware push flow while keeping the existing command behavior recognizable.
@hunk cli/src/commands/show.rs#2

This CLI change supports the packet-aware push flow while keeping the existing command behavior recognizable.
@hunk cli/src/commands/show.rs#3

This CLI change supports the packet-aware push flow while keeping the existing command behavior recognizable.
@hunk cli/src/commands/show.rs#4

This CLI change supports the packet-aware push flow while keeping the existing command behavior recognizable.
@hunk cli/src/config.rs#1

This CLI change supports the packet-aware push flow while keeping the existing command behavior recognizable.
@hunk cli/src/config.rs#2

This CLI change supports the packet-aware push flow while keeping the existing command behavior recognizable.
@hunk cli/src/main.rs#1

The packet parser owns the structured Markdown format, turns prose and diff references into JSON rows, and rejects incomplete or duplicate changed-line coverage.
@hunk cli/src/packet.rs#1

This CLI change supports the packet-aware push flow while keeping the existing command behavior recognizable.
@hunk cli/tests/integration.rs#1

## Narrative review surface and mobile polish
This section is the reviewer experience: packets render as the primary narrative, inline slices stay close to their explanation, and recent mobile/passive interaction polish keeps the page usable.

The stylesheet establishes the review page tokens and shared surface treatments used by both packet and classic diff views.
@hunk assets/css/app.css#1

The header and revision controls get the compact spacing and button styling that make the review page feel like one tool.
@hunk assets/css/app.css#2

Packet sections get sticky headers, concise metadata, and decision controls that stay usable without wrapping awkwardly.
@hunk assets/css/app.css#3

Decision pills keep their icon-first shape on mobile so selected state does not crowd the section header.
@hunk assets/css/app.css#4

Packet prose now tucks directly under the sticky section header, avoiding the thin visual gap during scroll.
@hunk assets/css/app.css#5

Packet prose and inline diff rows get enough rhythm to read as guidance rather than a stack of file cards.
@hunk assets/css/app.css#6

Classic file diffs use collapsible shells so large generated changes do not mount every expensive renderer up front.
@hunk assets/css/app.css#7

OAuth failures now log the safe Ueberauth reason, which made preview credential issues diagnosable from Fly logs.
@hunk lib/reviews_web/controllers/auth_controller.ex#1

OAuth failures now log the safe Ueberauth reason, which made preview credential issues diagnosable from Fly logs.
@hunk lib/reviews_web/controllers/auth_controller.ex#2

The LiveView initializes packet, file, and section expansion state alongside the selected revision.
@hunk lib/reviews_web/live/review_live.ex#1

Route and patchset selection refresh the review snapshot while preserving local expansion state when the revision does not change.
@hunk lib/reviews_web/live/review_live.ex#2

Diff style changes are pushed into both classic file renderers and packet inline diff slices.
@hunk lib/reviews_web/live/review_live.ex#3

Section decision clicks now refresh immediately, collapse the reviewed section, and keep pending overrides distinct from deleted local choices.
@hunk lib/reviews_web/live/review_live.ex#4

Publish and draft flows keep working around the packet-first review surface.
@hunk lib/reviews_web/live/review_live.ex#5

The page render chooses between packet narrative and full changes while sharing the same header and navigation context.
@hunk lib/reviews_web/live/review_live.ex#6

The authenticated user menu now uses a shorter sign-in affordance that fits mobile headers.
@hunk lib/reviews_web/live/review_live.ex#7

Snapshot assignment keeps file, packet, thread, and decision data together so subsequent LiveView patches render from fresh state.
@hunk lib/reviews_web/live/review_live.ex#8

Packet-aware helpers identify which file renderers need client-side updates when only inline slices are visible.
@hunk lib/reviews_web/live/review_live.ex#9

Decision state changes now delete a current local choice when toggled off, but still write pending when clearing an inherited prior choice.
@hunk lib/reviews_web/live/review_live.ex#10

The section collapse helper removes the reviewed section from the expanded set after a successful decision.
@hunk lib/reviews_web/live/review_live.ex#11

The remaining helpers keep line hints and review summaries small enough for the dense review UI.
@hunk lib/reviews_web/live/review_live.ex#12

The remaining helpers keep line hints and review summaries small enough for the dense review UI.
@hunk lib/reviews_web/live/review_live.ex#13

Diff components provide the shared wrappers for classic files and packet slices, including lazy rendering boundaries.
@hunk lib/reviews_web/live/review_live/diff_components.ex#1

Packet components render the section narrative, decision controls, effort estimates, collapsed summaries, and inline diff slices from the normalized packet shape.
@hunk lib/reviews_web/live/review_live/packet_components.ex#1

Revision navigation exposes direct version jumps plus previous and next movement, with labels that can collapse cleanly on mobile.
@hunk lib/reviews_web/live/review_live/revision_nav_components.ex#1

This change participates in the packet review flow and should be read as part of the surrounding section.
@hunk lib/reviews_web/router.ex#1

## Section decisions across revisions
This section adds reviewer state at the packet-section level and carries decisions forward only when the covered code still matches.

Section decision matching carries choices forward for unchanged sections and surfaces prior choices when a revision changes the covered lines.
@hunk lib/reviews/packet_section_decisions.ex#1

The decision schema stores reviewer, patchset, section identity, refs, and status for section-level review state.
@hunk lib/reviews/reviews/packet_section_decision.ex#1

The migration adds the storage needed for this part of the packet review model while preserving existing review data.
@hunk priv/repo/migrations/20260515120000_create_packet_section_decisions.exs#1

## Preview deployments and large diff performance
This section supports realistic demos and large reviews: preview apps can be bootstrapped, and big file diffs are stored and rendered lazily.

The preview workflow provisions per-PR Fly apps and passes the preview secrets into each deployment.
@hunk .github/workflows/fly-review.yml#1

The preview environment docs explain the OAuth limitation, synthetic preview user, shared database, and deployment flow.
@hunk docs/PREVIEW_ENVS.md#1

The release helper seeds a synthetic preview user from a configured token so the CLI can push to preview apps without GitHub OAuth.
@hunk lib/reviews/release.ex#1

The release helper seeds a synthetic preview user from a configured token so the CLI can push to preview apps without GitHub OAuth.
@hunk lib/reviews/release.ex#2

File records now carry per-file diff payloads and stats so large reviews avoid repeated full-diff parsing.
@hunk lib/reviews/reviews/file.ex#1

File records now carry per-file diff payloads and stats so large reviews avoid repeated full-diff parsing.
@hunk lib/reviews/reviews/file.ex#2

The migration adds the storage needed for this part of the packet review model while preserving existing review data.
@hunk priv/repo/migrations/20260515233649_add_diff_payload_to_files.exs#1

The release migration wrapper now also seeds the preview user during deploy when the preview token is present.
@hunk rel/overlays/bin/migrate#1

Regression coverage locks down the packet and preview behavior that reviewers and agents depend on.
@hunk test/reviews/release_test.exs#1

## Regression coverage
This section locks the behavior down across the parser, API, LiveView interactions, preview release helpers, and review packet rendering.

Regression coverage locks down the packet and preview behavior that reviewers and agents depend on.
@hunk test/reviews/review_packet_test.exs#1

Controller coverage verifies packet JSON storage and response metadata through the public API surface.
@hunk test/reviews_web/controllers/api/patchset_controller_test.exs#1

Controller coverage verifies packet JSON storage and response metadata through the public API surface.
@hunk test/reviews_web/controllers/api/review_controller_test.exs#1

Controller coverage verifies packet JSON storage and response metadata through the public API surface.
@hunk test/reviews_web/controllers/api/review_controller_test.exs#2

Controller coverage verifies packet JSON storage and response metadata through the public API surface.
@hunk test/reviews_web/controllers/api/review_controller_test.exs#3

Controller coverage verifies packet JSON storage and response metadata through the public API surface.
@hunk test/reviews_web/controllers/api/review_controller_test.exs#4

LiveView coverage exercises packet rendering, section decisions, inherited invalidation, mobile-friendly collapse behavior, and lazy diff rendering.
@hunk test/reviews_web/live/review_live_test.exs#1

LiveView coverage exercises packet rendering, section decisions, inherited invalidation, mobile-friendly collapse behavior, and lazy diff rendering.
@hunk test/reviews_web/live/review_live_test.exs#2
