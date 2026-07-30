# Outline-guided review layout

PR 58 reshapes Reviews around a compact outline guide: the active packet section becomes the reviewer's working context, the raw Diff route becomes a full-width fallback, and the landing page demonstrates the same interaction. Read the packet in order because the LiveView state model, component structure, and CSS geometry are deliberately coupled.

## Landing-page guide preview

The homepage demo is more than a cosmetic refresh: it now exercises the same mental model as the product surface. Review this section for fidelity rather than exact component reuse; the demo should teach the outline, focused section, file inventory, and diff relationship without becoming a second implementation of review behavior.

The first hunk derives the active section and decision states once before rendering. The following template rewrite replaces the old stack of independent section cards with a rail, a focused context panel, and an optional diff preview driven by that state.

@hunk lib/reviews_web/live/home_live.ex#1

@hunk lib/reviews_web/live/home_live.ex#2

The helper extraction turns the demo's file inventory into repeated rows with explicit status. Check that the simplified state vocabulary still tells the same story as the real guide without implying that the landing page is interactive review UI.

@hunk lib/reviews_web/live/home_live.ex#3

The final hunk documents and encodes the animation story. Its main risk is sequencing drift: the active section, decision cues, and v1/v2 stats should continue to agree at every demo step.

@hunk lib/reviews_web/live/home_live.ex#4

The first stylesheet group aligns the surrounding landing typography with shared tokens. These are mechanical-looking changes, but they prevent the demo from carrying a separate type scale and tracking system.

@hunk assets/css/landing.css#1

@hunk assets/css/landing.css#2

@hunk assets/css/landing.css#3

@hunk assets/css/landing.css#4

The next hunk replaces card-stack styling with the three-part guide geometry. Pay attention to the minimum widths: the demo needs enough room to resemble the real surface while still yielding predictably at its responsive breakpoint.

@hunk assets/css/landing.css#5

These hunks remove presentation rules that only supported the retired section-card animation and recast the remaining revision states around the focused panel and edge ticks.

@hunk assets/css/landing.css#6

@hunk assets/css/landing.css#7

@hunk assets/css/landing.css#8

The final landing rules update reduced-motion behavior and stack the diff preview beneath the guide on narrow screens. Verify that the responsive layout remains legible rather than merely hiding overflow.

@hunk assets/css/landing.css#9

@hunk assets/css/landing.css#10

These assertions intentionally stay light: they protect the demo's visible state transitions while leaving detailed guide behavior to the review LiveView suite.

@hunk test/reviews_web/live/home_live_test.exs#1

@hunk test/reviews_web/live/home_live_test.exs#2

## Review state, navigation, and fallback diff

This section is the behavioral spine of the change. The LiveView must keep one active guide section stable during ordinary refreshes, reset it sensibly across revisions, and refuse split mode on viewports where side-by-side code is not usable.

The initial assign replaces file-level expansion state with active outline state. That is an ownership shift: the guide decides what context is active, while hunk expansion remains independent.

@hunk lib/reviews_web/live/review_live.ex#1

The server-side tablet guard is the authority behind the client lock. Even if a stale event or manipulated button requests split mode, a tablet-tagged request cannot change the socket.

@hunk lib/reviews_web/live/review_live.ex#2

Section toggles now also establish focus. This keeps existing expansion behavior but gives the guide a stable section identity to render.

@hunk lib/reviews_web/live/review_live.ex#3

Overview and guide-section selection are explicit events. In split mode they also push a targeted scroll event, so check both state mutation and navigation destination rather than treating these as equivalent to the old disclosure toggles.

@hunk lib/reviews_web/live/review_live.ex#4

The diff-style control advertises its tablet breakpoint to the colocated hook and marks split as requiring width. These attributes are also the contract exercised by the LiveView tests.

@hunk lib/reviews_web/live/review_live.ex#5

The hook synchronizes local preference, media-query state, disabled semantics, and server state. Its `updated` callback matters: LiveView patches can replace the attributes added during `mounted`, so the lock must be reapplied without creating an event loop.

@hunk lib/reviews_web/live/review_live.ex#6

The render shell computes packet presence once, distinguishes Guide from Diff layout classes, and suppresses the large packet header in focused Guide mode.

@hunk lib/reviews_web/live/review_live.ex#7

Revision navigation receives separate packet-presence and outline-availability signals. This prevents the Diff route from offering controls that only exist in Guide mode.

@hunk lib/reviews_web/live/review_live.ex#8

The packet component receives active focus, while the Diff fallback drops file-tree and file-expansion inputs that it no longer owns.

@hunk lib/reviews_web/live/review_live.ex#9

The snapshot path removes obsolete file expansion bookkeeping.

@hunk lib/reviews_web/live/review_live.ex#10

Active focus is preserved only within the same patchset. The helper clamps stale indices and selects the first section when moving to a new packet-bearing revision, which is the key behavior to challenge during review.

@hunk lib/reviews_web/live/review_live.ex#11

@hunk lib/reviews_web/live/review_live.ex#12

@hunk lib/reviews_web/live/review_live.ex#13

The revision component separates “a packet exists” from “the outline can be shown.”

@hunk lib/reviews_web/live/review_live/revision_nav_components.ex#1

The outline restore control now follows that narrower availability signal.

@hunk lib/reviews_web/live/review_live/revision_nav_components.ex#2

The old mode-flip link becomes an explicit Guide/Diff tablist so the current route is visible rather than inferred from the opposite action label.

@hunk lib/reviews_web/live/review_live/revision_nav_components.ex#3

The path helpers keep revision query parameters intact in both directions.

@hunk lib/reviews_web/live/review_live/revision_nav_components.ex#4

The Diff fallback deliberately removes the file tree and open-thread sidebar, leaving one full-width file sequence. This is a product tradeoff, not dead-code cleanup: confirm that raw diff scanning is better served by width than by the retired secondary navigation.

@hunk lib/reviews_web/live/review_live/diff_components.ex#1

The remaining helper deletion follows from that ownership change.

@hunk lib/reviews_web/live/review_live/diff_components.ex#2

The app hook registry drops the two retired hooks and retains only behavior still mounted by the new surface.

@hunk assets/js/app.js#1

The new flyout hook manages outside-click and Escape dismissal for the compact rail menu. Review its listener cleanup because the shell is LiveView-managed.

@hunk assets/js/hooks/guide_flyout.js#1

These deleted hooks correspond to UI that no longer exists: the Changes file tree and sticky prose cover. Their removal should stay aligned with the template and CSS deletions later in the packet.

@hunk assets/js/hooks/changes_file_tree.js#1

@hunk assets/js/hooks/sticky_prose.js#1

## Focused packet rendering

Packet components now own the outline rail, focused overview, compact file inventory, section actions, flyout navigation, and inline hunk sequence. The important boundary is that these components derive presentation from packet data and LiveView assigns; they do not create a second source of review state.

The entry-point hunk builds the outline read model once and threads active focus into the packet renderer.

@hunk lib/reviews_web/live/review_live/packet_components.ex#1

Existing section disclosure now asks the guide-aware predicate whether a section is open.

@hunk lib/reviews_web/live/review_live/packet_components.ex#2

Summary and body visibility diverge between focused Guide mode and the older stacked mode. Only the active unified section should render; split mode keeps the packet stream while exposing focused context in the guide panel.

@hunk lib/reviews_web/live/review_live/packet_components.ex#3

The active section's introductory prose is flagged for deduplication because the guide panel already presents it.

@hunk lib/reviews_web/live/review_live/packet_components.ex#4

This large hunk introduces the guide shell itself: edge rail, overview and section panels, file rows, actions, and the full flyout outline. Review it as one composition boundary and check that controls dispatch LiveView events rather than mutating local presentation state.

@hunk lib/reviews_web/live/review_live/packet_components.ex#5

The helper block defines focused-mode visibility, section selection, outline file aggregation, progress, and per-file state. Pay particular attention to aggregation rules when one file appears in multiple hunks or carries mixed viewed/decision state.

@hunk lib/reviews_web/live/review_live/packet_components.ex#6

The existing navigation builder is renamed to distinguish its read-model role from the new rendered guide.

@hunk lib/reviews_web/live/review_live/packet_components.ex#7

Section summaries stop truncating at 150 characters because the focused panel has room for authored context.

@hunk lib/reviews_web/live/review_live/packet_components.ex#8

The obsolete truncation helper is removed accordingly.

@hunk lib/reviews_web/live/review_live/packet_components.ex#9

Status and pluralization helpers keep compact labels out of the template branches.

@hunk lib/reviews_web/live/review_live/packet_components.ex#10

The row renderer accepts a dedupe flag only for the active section's introductory markdown.

@hunk lib/reviews_web/live/review_live/packet_components.ex#11

The body is transformed before render rather than hidden with CSS.

@hunk lib/reviews_web/live/review_live/packet_components.ex#12

Unified mode opts hunk cards into sticky headers; split mode keeps headers inline.

@hunk lib/reviews_web/live/review_live/packet_components.ex#13

Intro deduplication removes only the first paragraph block and preserves later prose. This parser-like logic is worth reading carefully around headings, blank lines, lists, and packets whose first markdown row is not a paragraph.

@hunk lib/reviews_web/live/review_live/packet_components.ex#14

Packet units mark exactly one introductory markdown row so deduplication cannot leak into later annotations.

@hunk lib/reviews_web/live/review_live/packet_components.ex#15

The dedupe decision is carried through section units.

@hunk lib/reviews_web/live/review_live/packet_components.ex#16

Sticky-header intent is also carried through the hunk rendering path.

@hunk lib/reviews_web/live/review_live/packet_components.ex#17

@hunk lib/reviews_web/live/review_live/packet_components.ex#18

Only the marked intro unit receives the body transformation.

@hunk lib/reviews_web/live/review_live/packet_components.ex#19

The hunk card accepts sticky intent as explicit input.

@hunk lib/reviews_web/live/review_live/packet_components.ex#20

The final class and hook wiring makes sticky behavior conditional, avoiding observers and sticky positioning in layouts where headers should remain inline.

@hunk lib/reviews_web/live/review_live/packet_components.ex#21

## Layout, theming, and responsive behavior

The CSS is large because it replaces the review page's spatial model. Review it in layers: shared tokens, compact shell, packet flow, diff containment, guide geometry, then mobile overrides. Most regressions here will appear as an incorrect grid track or sticky ancestor rather than a wrong color.

Shared product-shell aliases expose review colors to every surface before packet CSS consumes them.

@hunk assets/css/product-shell.css#1

The token additions supply flat tracking and the wider-screen guide dimensions.

@hunk assets/css/tokens.css#1

@hunk assets/css/tokens.css#2

Packet CSS removes its duplicated light and dark palettes and inherits the shared review aliases. Confirm that standalone review pages still receive every variable they reference.

@hunk assets/css/packet.css#1

@hunk assets/css/packet.css#2

Guide mode hides the redundant page header, while non-guide and packetless routes retain a smaller version of the existing header.

@hunk assets/css/packet.css#3

@hunk assets/css/packet.css#4

@hunk assets/css/packet.css#5

Disabled split controls get explicit affordance at tablet widths.

@hunk assets/css/packet.css#6

These small substitutions remove fallback colors now guaranteed by the shared token layer.

@hunk assets/css/packet.css#7

@hunk assets/css/packet.css#8

The packet shell gains separate unified and split track definitions. Unified reserves room for rail plus focus panel; split keeps only the rail beside the packet stream.

@hunk assets/css/packet.css#9

The packet stream is constrained and padded independently from the guide, with an inline overview target for split-mode navigation.

@hunk assets/css/packet.css#10

Section summaries are no longer globally sticky.

@hunk assets/css/packet.css#11

Unified Guide mode hides inactive sections and their duplicate summaries.

@hunk assets/css/packet.css#12

Sticky hunk offsets are simplified now that sticky prose is gone, with a separate offset for the unified guide.

@hunk assets/css/packet.css#13

Decision colors move onto the review token vocabulary.

@hunk assets/css/packet.css#14

@hunk assets/css/packet.css#15

Focused section controls get their own compact row.

@hunk assets/css/packet.css#16

Markdown rows return to normal document flow. This is the CSS half of removing StickyProse and should be checked against long context blocks between hunks.

@hunk assets/css/packet.css#17

File groups and hunk cards can now shrink below their intrinsic diff width.

@hunk assets/css/packet.css#18

File-diff bodies own horizontal overflow so a narrow code block cannot widen the whole document.

@hunk assets/css/packet.css#19

Hunk summaries are inline by default.

@hunk assets/css/packet.css#20

Only cards explicitly marked sticky in unified Guide mode regain sticky positioning.

@hunk assets/css/packet.css#21

The comment composer follows the inherited panel token.

@hunk assets/css/packet.css#22

With the Diff sidebar removed, the shell must collapse to one track. This rule is what prevents an empty desktop column from constraining the renderer.

@hunk assets/css/packet.css#23

The largest style hunk defines the guide shell, rail, ticks, focus panel, file rows, flyout, state cues, and transitions. Review its stacking contexts and overflow ancestors together: sticky headers, flyout visibility, and full-height scrolling depend on them.

@hunk assets/css/packet.css#24

The remaining dark literal is replaced with a themed panel value.

@hunk assets/css/packet.css#25

File status colors use the shared review aliases.

@hunk assets/css/packet.css#26

At mobile width the split control disappears, both guide variants collapse to one explicit track, the rail becomes horizontal, and the focus panel stacks above packet content. The more-specific guide selectors are intentional so desktop class rules cannot win the cascade.

@hunk assets/css/packet.css#27

The trailing cleanup removes a stale mobile rule superseded by the new stack.

@hunk assets/css/packet.css#28

## Packet authoring guidance

The bundled skill now asks authors to write for reviewer intent rather than merely satisfy coverage. These changes are small, but they directly affect whether future packets use the extra space introduced by this PR well.

The template language explicitly encourages orienting prose before hunk references.

@hunk skills/writing-review-packets/SKILL.md#1

The method now treats subheadings as occasional scan landmarks and distinguishes useful context from line-by-line narration.

@hunk skills/writing-review-packets/SKILL.md#2

## Regression coverage

The tests are organized around behavioral contracts rather than CSS screenshots. Read them alongside the preview checks: they should catch state and route regressions, while browser verification remains responsible for geometry and overflow.

The first test proves the server rejects tablet-origin split requests while preserving split on wide viewports.

@hunk test/reviews_web/live/review_live_test.exs#1

Existing effort and line-stat assertions move to the focused section panel.

@hunk test/reviews_web/live/review_live_test.exs#2

This hunk verifies intro prose is represented in the guide without being duplicated in the packet stream, and that split-mode hunk headers remain inline.

@hunk test/reviews_web/live/review_live_test.exs#3

Small-section expansion is now driven by selecting a focused guide section.

@hunk test/reviews_web/live/review_live_test.exs#4

Unified mode renders only the active section and changes focus through the edge tick.

@hunk test/reviews_web/live/review_live_test.exs#5

The route test establishes the explicit Guide/Diff tab contract and asserts the retired file tree is absent.

@hunk test/reviews_web/live/review_live_test.exs#6

The broad fallback test checks both diff styles, absence of guide/sidebar UI, inline headers, and full-file grouping. This is the main regression net for the simplified Diff route.

@hunk test/reviews_web/live/review_live_test.exs#7

Packetless reviews keep the same full-width fallback without acquiring packet-only navigation.

@hunk test/reviews_web/live/review_live_test.exs#8

@hunk test/reviews_web/live/review_live_test.exs#9

Large-diff coverage confirms lazy rendering still works after the sidebar and file-expansion state are removed.

@hunk test/reviews_web/live/review_live_test.exs#10

Outline preference is exercised in both split and unified guide layouts.

@hunk test/reviews_web/live/review_live_test.exs#11

The persisted hidden preference remains effective after reconnecting and changing diff style.

@hunk test/reviews_web/live/review_live_test.exs#12

Decision transitions continue to leave the active section open, preserving context while reviewers approve, deny, or ignore work.

@hunk test/reviews_web/live/review_live_test.exs#13
