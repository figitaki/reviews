// Translation between server-side `side` ("old" | "new") and the diff library's
// `annotationSide` ("deletions" | "additions"). The translator runs exactly
// twice per round-trip — once when grouping incoming threads/drafts into
// line annotations, once when shipping a save_draft payload back — and never
// leaks into bubble components or pushEvent payloads.

import { Annotation } from "../schemas.js"
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
