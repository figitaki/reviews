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
