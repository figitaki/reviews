// Wire-format contracts for the Reviews diff renderer.
//
// Mirrors `lib/reviews/review_view.ex` (thread_to_payload) and the
// `create_comment` LiveView event. Validation happens at every boundary the JS
// island sees: the per-file `data-threads` JSON read on mount, the
// `threads_updated:<file>` server-pushed payloads, and the pushEvent payloads
// we send back. Wire-format drift fails loudly here rather than silently
// mis-rendering.

import { z } from "zod"

const Side = z.enum(["old", "new"])

const Author = z
  .object({
    id: z.number(),
    username: z.string(),
    avatar_url: z.string().url().nullable().optional(),
  })
  .nullable()

const LineAnchor = z.object({
  granularity: z.literal("line"),
  line_number_hint: z.number().int(),
  line_text: z.string().optional(),
  context_before: z.array(z.string()).default([]),
  context_after: z.array(z.string()).default([]),
})

const TokenRangeAnchor = z.object({
  granularity: z.literal("token_range"),
  line_number_hint: z.number().int(),
  line_text: z.string().optional(),
  context_before: z.array(z.string()).default([]),
  context_after: z.array(z.string()).default([]),
  selection_text: z.string(),
  // Older token_range threads pre-date the offset field; treat as optional.
  // v2 always populates it.
  selection_offset: z.number().int().nonnegative().optional(),
})

export const Anchor = z.discriminatedUnion("granularity", [
  LineAnchor,
  TokenRangeAnchor,
])

export const Comment = z.object({
  id: z.number(),
  body: z.string(),
  author: Author,
  inserted_at: z.string().nullable(),
  updated_at: z.string().nullable().optional(),
})

export const Thread = z.object({
  id: z.number(),
  file_path: z.string(),
  side: Side,
  anchor: Anchor,
  status: z.enum(["open", "resolved", "outdated"]),
  inserted_at: z.string().nullable().optional(),
  author: Author,
  comments: z.array(Comment),
})

export const CreateCommentPayload = z.object({
  file_path: z.string(),
  side: Side,
  body: z.string().min(1),
  thread_id: z.number().nullable().optional(),
  thread_anchor: Anchor,
  line_text: z.string().optional(),
})

// --- Hunk island dataset -----------------------------------------------------
//
// The DiffRenderer island's `data-*` attributes are the state channel between
// LiveView and the Pierre renderer (LiveView patches attributes even on
// phx-update="ignore" nodes). This schema is the single point of coercion:
// dataset values are always strings, so booleans and integers are coerced
// here, and `data-hunk-attrs` (the grouped-hunk payload) is parsed and
// validated rather than passed around as an opaque string.

const datasetBool = z
  .enum(["true", "false"])
  .default("false")
  .transform((value) => value === "true")

const presentOrUndefined = (value) =>
  value == null || value === "" ? undefined : value

const datasetInt = z.preprocess(
  presentOrUndefined,
  z.coerce.number().int().optional()
)

const datasetString = z.preprocess(presentOrUndefined, z.string().optional())

export const HunkAttrs = z.object({
  file_path: z.string().min(1),
  row_ref: z.string().min(1),
  hunk_fingerprint: z.string().min(1),
  hunk_index: z.number().int(),
  line_start: z.number().int().nullable().optional(),
  line_end: z.number().int().nullable().optional(),
})

const jsonArray = (schema) =>
  z.preprocess(presentOrUndefined, z
    .string()
    .transform((raw, ctx) => {
      try {
        return JSON.parse(raw)
      } catch {
        ctx.addIssue({ code: "custom", message: "invalid JSON" })
        return z.NEVER
      }
    })
    .pipe(z.array(schema))
    .optional())

export const HunkIslandDataset = z.object({
  hunkId: z.string().min(1),
  hunkLabel: z.string().default(""),
  hunkDetails: z.string().default(""),
  hunkExpanded: datasetBool,
  hunkViewed: datasetBool,
  hunkPartiallyViewed: datasetBool,
  hunkViewState: z.string().default(""),
  signedIn: datasetBool,
  filePath: z.string().min(1),
  rowRef: datasetString,
  hunkFingerprint: datasetString,
  hunkAttrs: jsonArray(HunkAttrs),
  hunkIndex: datasetInt,
  lineStart: datasetInt,
  lineEnd: datasetInt,
  sectionIndex: datasetInt,
  sectionTitle: datasetString,
})

// What we push back for mark_hunk_viewed / mark_hunk_unviewed. Mirrors
// `hunk_attrs_from_params` in `lib/reviews_web/live/review_live.ex`.
export const HunkViewPayload = z.object({
  file_path: z.string().min(1),
  row_ref: z.string().min(1).optional(),
  hunk_fingerprint: z.string().min(1).optional(),
  hunk_id: z.string().min(1),
  hunk_attrs: z.string().optional(),
  hunk_index: z.number().int().optional(),
  line_start: z.number().int().optional(),
  line_end: z.number().int().optional(),
  section_index: z.number().int().optional(),
  section_title: z.string().optional(),
})

export function hunkViewPayload(island) {
  return HunkViewPayload.parse({
    file_path: island.filePath,
    row_ref: island.rowRef,
    hunk_fingerprint: island.hunkFingerprint,
    hunk_id: island.hunkId,
    hunk_attrs: island.hunkAttrs ? JSON.stringify(island.hunkAttrs) : undefined,
    hunk_index: island.hunkIndex,
    line_start: island.lineStart,
    line_end: island.lineEnd,
    section_index: island.sectionIndex,
    section_title: island.sectionTitle,
  })
}

// Client-internal annotation shape — NOT a wire format. This is what we feed
// Pierre Diffs via `lineAnnotations`. `side` is the library's terminology
// (additions/deletions); see `lib/translate.js` for the translation.
export const AnnotationSide = z.enum(["additions", "deletions"])

export const Annotation = z.object({
  side: AnnotationSide,
  lineNumber: z.number().int().positive(),
  metadata: z.object({
    threads: z.array(Thread).default([]),
  }),
})
