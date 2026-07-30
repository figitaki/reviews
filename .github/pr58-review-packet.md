# Outline-guided review layout

PR 58 reshapes Reviews around a compact outline guide: the active packet section becomes the reviewer's working context, the raw Changes route becomes a full-width fallback, and the same interaction is demonstrated on the landing page. This packet follows the implementation from product framing through responsive behavior and regression coverage.

## Landing-page guide preview

The homepage demo now mirrors the real review surface closely enough to communicate the outline, focused section, file list, and diff relationship without maintaining a second visual language.

@hunk lib/reviews_web/live/home_live.ex#1

@hunk lib/reviews_web/live/home_live.ex#2

@hunk lib/reviews_web/live/home_live.ex#3

@hunk lib/reviews_web/live/home_live.ex#4

@hunk assets/css/landing.css#1

@hunk assets/css/landing.css#2

@hunk assets/css/landing.css#3

@hunk assets/css/landing.css#4

@hunk assets/css/landing.css#5

@hunk assets/css/landing.css#6

@hunk assets/css/landing.css#7

@hunk assets/css/landing.css#8

@hunk assets/css/landing.css#9

@hunk assets/css/landing.css#10

@hunk test/reviews_web/live/home_live_test.exs#1

@hunk test/reviews_web/live/home_live_test.exs#2

## Review state, navigation, and fallback diff

The LiveView keeps section focus stable across refreshes, locks narrow viewports to unified diffs, and separates Guide from a simplified full-width Changes route. The supporting hooks are reduced to the behavior the new layout still owns.

@hunk lib/reviews_web/live/review_live.ex#1

@hunk lib/reviews_web/live/review_live.ex#2

@hunk lib/reviews_web/live/review_live.ex#3

@hunk lib/reviews_web/live/review_live.ex#4

@hunk lib/reviews_web/live/review_live.ex#5

@hunk lib/reviews_web/live/review_live.ex#6

@hunk lib/reviews_web/live/review_live.ex#7

@hunk lib/reviews_web/live/review_live.ex#8

@hunk lib/reviews_web/live/review_live.ex#9

@hunk lib/reviews_web/live/review_live.ex#10

@hunk lib/reviews_web/live/review_live.ex#11

@hunk lib/reviews_web/live/review_live.ex#12

@hunk lib/reviews_web/live/review_live.ex#13

@hunk lib/reviews_web/live/review_live/revision_nav_components.ex#1

@hunk lib/reviews_web/live/review_live/revision_nav_components.ex#2

@hunk lib/reviews_web/live/review_live/revision_nav_components.ex#3

@hunk lib/reviews_web/live/review_live/revision_nav_components.ex#4

@hunk lib/reviews_web/live/review_live/diff_components.ex#1

@hunk lib/reviews_web/live/review_live/diff_components.ex#2

@hunk assets/js/app.js#1

@hunk assets/js/hooks/guide_flyout.js#1

@hunk assets/js/hooks/changes_file_tree.js#1

@hunk assets/js/hooks/sticky_prose.js#1

## Focused packet rendering

Packet components now own the outline rail, focused overview, compact file inventory, section actions, flyout navigation, and the guide's inline hunk sequence. Review this section for component boundaries and consistency between unified and split modes.

@hunk lib/reviews_web/live/review_live/packet_components.ex#1

@hunk lib/reviews_web/live/review_live/packet_components.ex#2

@hunk lib/reviews_web/live/review_live/packet_components.ex#3

@hunk lib/reviews_web/live/review_live/packet_components.ex#4

@hunk lib/reviews_web/live/review_live/packet_components.ex#5

@hunk lib/reviews_web/live/review_live/packet_components.ex#6

@hunk lib/reviews_web/live/review_live/packet_components.ex#7

@hunk lib/reviews_web/live/review_live/packet_components.ex#8

@hunk lib/reviews_web/live/review_live/packet_components.ex#9

@hunk lib/reviews_web/live/review_live/packet_components.ex#10

@hunk lib/reviews_web/live/review_live/packet_components.ex#11

@hunk lib/reviews_web/live/review_live/packet_components.ex#12

@hunk lib/reviews_web/live/review_live/packet_components.ex#13

@hunk lib/reviews_web/live/review_live/packet_components.ex#14

@hunk lib/reviews_web/live/review_live/packet_components.ex#15

@hunk lib/reviews_web/live/review_live/packet_components.ex#16

@hunk lib/reviews_web/live/review_live/packet_components.ex#17

@hunk lib/reviews_web/live/review_live/packet_components.ex#18

@hunk lib/reviews_web/live/review_live/packet_components.ex#19

@hunk lib/reviews_web/live/review_live/packet_components.ex#20

@hunk lib/reviews_web/live/review_live/packet_components.ex#21

## Layout, theming, and responsive behavior

The styling establishes the edge rail and focused panel on wide screens, stacks Guide content on mobile, contains raw diffs at narrow widths, and keeps the Changes route full-width after removing its sidebar. The shared shell and token changes support the same geometry outside the review page.

@hunk assets/css/packet.css#1

@hunk assets/css/packet.css#2

@hunk assets/css/packet.css#3

@hunk assets/css/packet.css#4

@hunk assets/css/packet.css#5

@hunk assets/css/packet.css#6

@hunk assets/css/packet.css#7

@hunk assets/css/packet.css#8

@hunk assets/css/packet.css#9

@hunk assets/css/packet.css#10

@hunk assets/css/packet.css#11

@hunk assets/css/packet.css#12

@hunk assets/css/packet.css#13

@hunk assets/css/packet.css#14

@hunk assets/css/packet.css#15

@hunk assets/css/packet.css#16

@hunk assets/css/packet.css#17

@hunk assets/css/packet.css#18

@hunk assets/css/packet.css#19

@hunk assets/css/packet.css#20

@hunk assets/css/packet.css#21

@hunk assets/css/packet.css#22

@hunk assets/css/packet.css#23

@hunk assets/css/packet.css#24

@hunk assets/css/packet.css#25

@hunk assets/css/packet.css#26

@hunk assets/css/packet.css#27

@hunk assets/css/packet.css#28

@hunk assets/css/product-shell.css#1

@hunk assets/css/tokens.css#1

@hunk assets/css/tokens.css#2

## Packet authoring guidance

The bundled authoring skill is tightened around reviewer intent, stable section identity, and useful prose rather than mechanical narration.

@hunk skills/writing-review-packets/SKILL.md#1

@hunk skills/writing-review-packets/SKILL.md#2

## Regression coverage

The LiveView suite exercises focus preservation, revision behavior, guide and Changes routing, responsive hooks, file-diff rendering, and the removal of obsolete sidebar state.

@hunk test/reviews_web/live/review_live_test.exs#1

@hunk test/reviews_web/live/review_live_test.exs#2

@hunk test/reviews_web/live/review_live_test.exs#3

@hunk test/reviews_web/live/review_live_test.exs#4

@hunk test/reviews_web/live/review_live_test.exs#5

@hunk test/reviews_web/live/review_live_test.exs#6

@hunk test/reviews_web/live/review_live_test.exs#7

@hunk test/reviews_web/live/review_live_test.exs#8

@hunk test/reviews_web/live/review_live_test.exs#9

@hunk test/reviews_web/live/review_live_test.exs#10

@hunk test/reviews_web/live/review_live_test.exs#11

@hunk test/reviews_web/live/review_live_test.exs#12

@hunk test/reviews_web/live/review_live_test.exs#13
