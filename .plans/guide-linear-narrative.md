# Guide layout iteration: linear reviewer narrative

Next iteration of the PR #58 focused guide layout, incorporating the revert
feedback on the "Redesign guided review section flow" pass (0b5cacc, reverted
in de3fd9c). Feedback source:
https://github.com/figitaki/reviews/pull/58#issuecomment-5197239209

## Goal

A linear reviewer narrative per section, with **code width and prose width as
different layout concerns**, and review state visible without competing with
section navigation.

Reading order inside a section:

1. **Section header** — number + title, meta, and review state (current
   decision, outdated decision from an earlier revision, inherited/carried
   state) legible *before* the reviewer starts reading.
2. **Grounding context** — the section's authored lead prose, at a reading
   measure.
3. **Hunks** — supporting context kept visually close, occasional interspersed
   prose where the diff alone is insufficient.
4. **Section decision** — approve / request changes / skip controls at the end
   of the flow.

## What 0b5cacc got wrong (and this pass must not repeat)

- **Detached overview slab**: the section overview stayed a separate
  `<section class="review-packet-inline-overview">` block with its own width
  and typography. → This pass renders it as the section's *own header*,
  sharing the content track's left edge and rhythm.
- **Prose widened to the track**: prose went 58ch→68ch inside a 72ch
  container, erasing the prose/code distinction. → Prose keeps a narrow
  measure (~60ch); the track itself can be wide for code.
- **Overlapping micro-badge on rail ticks**: a 12px state icon pinned over the
  corner of a 24px tick. → Decision state is a separate, non-overlapping
  glyph slot under the number, with its own accessible label; the number
  itself never takes decision colors (that part of 0b5cacc was right).
- **File inventory `<details>` between prose and code**: collapsed-by-default
  didn't fix its placement. → File inventory is removed from the reading
  sequence entirely; file navigation lives in the flyout.
- **De-chromed hunk cards** left the annotation strip floating with nothing to
  attach to. → Keep the card container; context prose shares the card's track
  and hugs the hunk it introduces.
- **Hand-written dataset coercion**: `optionalInteger` + `compactHunkPayload`
  + 15 unvalidated `data-*` reads. → Zod schemas in `assets/js/schemas.js`
  (`z.coerce` ints, boolean coercion, `.optional()`), parsed once at the
  renderer boundary; payload built from the parsed object.

## What carries forward from 0b5cacc

- **One hunk header, owned by Pierre**: current HEAD renders *two* headers on
  an expanded hunk (HEEx `.review-hunk-summary` + Pierre's file header). The
  fix stands: delete the HEEx header, mount the island always, drive collapse
  through Pierre's `collapsed` option, and augment via `renderHeaderPrefix`
  (toggle — Pierre has no native one) and `renderHeaderMetadata` (hunk label,
  viewed state, Mark viewed). Sticky hunk header hook goes away with it.
- Copy: "Changes requested" / "Skipped" / "Pending", actions "Approve" /
  "Request changes" / "Skip".
- Prose form of stale-decision history ("The approved decision from v1 is
  outdated for v2.") instead of the cryptic pill + chevron pair.
- `section_decision_state_label/1` carried-forward distinction; per-section
  `hunk_count` / `viewed_count` / `progress_percent` on the outline.
- Decision controls at the end of the section (`packet_section_decision`
  footer) — matches the intended reading order; the header shows *state*.
- `aria-pressed` on decision buttons; visible diff-style chip labels; the
  `npm test` script for renderer unit tests.

## Feedback → design decisions

| # | Feedback | Decision |
|---|----------|----------|
| 1 | Overview aligned with content track | Section overview becomes the section header: same container, same left edge as the prose/code below it. No independent centering or width. |
| 2 | Review state in section header | Header shows current decision, previous/outdated decision prose, and carried-forward state up front. Controls live in the decision footer. |
| 3 | Prose reading measure | `--guide-measure: 60ch` for authored prose (summaries, markdown rows, overview prose). Hunk rows use the full content track. |
| 4 | Neutral rail numbers | Tick numbers always neutral. Decision state is a distinct glyph rendered in its own slot next to/below the number with `aria-label`/`title`. |
| 5 | No file inventory in reading flow | Removed from the inline section panel. Flyout keeps per-section file jump list. |
| 6 | One hunk header | Pierre's header only. Island always mounted; `collapsed` option; controls injected via header slots; dataset is the state channel, validated per #8. |
| 7 | Context close to hunk | Annotation prose keeps the hug (`margin-bottom` into the card), shares the card track, card keeps its border/background. |
| 8 | Zod at renderer boundary | `HunkUIDataset` (+ event payload schema) in `schemas.js`; single `parse` of `this.el.dataset` in the hook; no ad-hoc coercion helpers. |
