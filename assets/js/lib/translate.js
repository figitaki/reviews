// Translation between server-side `side` ("old" | "new") and the diff library's
// `annotationSide` ("deletions" | "additions"). The translator runs exactly
// twice per round-trip — once when grouping incoming threads/drafts into
// line annotations, once when shipping a save_draft payload back — and never
// leaks into bubble components or pushEvent payloads.

import { Anchor, Annotation } from "../schemas.js"
import { groupBy, keyUnion } from "./fp.js"

export const sideToAnnotationSide = (side) =>
  side === "old" ? "deletions" : side === "new" ? "additions" : null

export const annotationSideToSide = (side) =>
  side === "deletions" ? "old" : side === "additions" ? "new" : null

const annotationKey = (item) =>
  `${sideToAnnotationSide(item.side)}:${item.anchor.line_number_hint}`

// (Thread[], Draft[]) -> Annotation[]
// Groups threads and drafts by (annotationSide, lineNumber) so PatchDiff
// can attach them to the right rendered line via lineAnnotations.
export function threadsAndDraftsToAnnotations(threads, drafts) {
  const threadGroups = groupBy(threads, annotationKey)
  const draftGroups = groupBy(drafts, annotationKey)

  return [...keyUnion(threadGroups, draftGroups)].map((key) => {
    const [side, lineNumber] = key.split(":")
    return Annotation.parse({
      side,
      lineNumber: Number(lineNumber),
      metadata: {
        threads: threadGroups.get(key) ?? [],
        drafts: draftGroups.get(key) ?? [],
      },
    })
  })
}

// composerToAnchor(composer) -> Anchor
// Builds the wire-format `thread_anchor` from the composer's local state,
// branching on `composer.kind`. Token-range composers carry the substring
// offsets reported by <PatchDiff>'s onTokenClick; line composers just pin
// to the line number. `Anchor.parse(...)` runs as a tripwire — if the
// composer state somehow falls outside the schema (missing selection_text
// on a token composer, etc.) we fail loudly here instead of sending bogus
// JSON to the server.
//
// `context_before` / `context_after` go out as [] until the library exposes
// surrounding context; the server-side anchoring already tolerates this.
//
// @example composerToAnchor({ kind: "line", lineNumber: 12, lineText: "foo" })
//   => { granularity: "line", line_number_hint: 12, line_text: "foo",
//        context_before: [], context_after: [] }
// @example composerToAnchor({
//   kind: "token", lineNumber: 12, lineText: "  let x = 1",
//   lineCharStart: 6, lineCharEnd: 7, tokenText: "x",
// }) => { granularity: "token_range", line_number_hint: 12,
//         line_text: "  let x = 1", selection_text: "x",
//         selection_offset: 6, context_before: [], context_after: [] }
export function composerToAnchor(composer) {
  if (composer.kind === "token") {
    return Anchor.parse({
      granularity: "token_range",
      line_text: composer.lineText,
      line_number_hint: composer.lineNumber,
      selection_text: composer.tokenText,
      selection_offset: composer.lineCharStart,
      context_before: [],
      context_after: [],
    })
  }
  return Anchor.parse({
    granularity: "line",
    line_text: composer.lineText,
    line_number_hint: composer.lineNumber,
    context_before: [],
    context_after: [],
  })
}
