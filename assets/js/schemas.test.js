import assert from "node:assert/strict"
import { test } from "node:test"

import { HunkIslandDataset, hunkViewPayload } from "./schemas.js"

const baseDataset = {
  fileId: "hunk-1-packet-section-0-row-0--hunk-lib-a-ex-1",
  filePath: "lib/a.ex",
  fileStatus: "modified",
  side: "new",
  rawDiff: "@@ -1 +1 @@\n-old\n+new\n",
  threads: "[]",
  signedIn: "true",
  diffStyle: "split",
  hunkId: "packet-section-0-row-0--hunk-lib-a-ex-1",
  hunkLabel: "hunk 1 · L1-L2",
  hunkDetails: "lib/a.ex · hunk 1 · L1-L2 · 1 additions, 1 deletions",
  hunkExpanded: "true",
  hunkViewed: "false",
  hunkPartiallyViewed: "false",
  hunkViewState: "",
  rowRef: "lib/a.ex#h1",
  hunkFingerprint: "abc123",
  hunkIndex: "1",
  lineStart: "1",
  lineEnd: "2",
  sectionIndex: "0",
  sectionTitle: "Main change",
}

test("coerces dataset strings into typed island state", () => {
  const island = HunkIslandDataset.parse(baseDataset)

  assert.equal(island.diffStyle, "split")
  assert.equal(island.hunkExpanded, true)
  assert.equal(island.hunkViewed, false)
  assert.equal(island.signedIn, true)
  assert.equal(island.hunkIndex, 1)
  assert.equal(island.lineStart, 1)
  assert.equal(island.lineEnd, 2)
  assert.equal(island.sectionIndex, 0)
  assert.equal(island.hunkAttrs, undefined)
})

test("unknown diff style falls back to split", () => {
  const island = HunkIslandDataset.parse({ ...baseDataset, diffStyle: "bogus" })
  assert.equal(island.diffStyle, "split")
  assert.equal(
    HunkIslandDataset.parse({ ...baseDataset, diffStyle: "unified" }).diffStyle,
    "unified"
  )
})

test("blank optional dataset values become undefined, not 0 or ''", () => {
  const island = HunkIslandDataset.parse({
    ...baseDataset,
    lineStart: "",
    lineEnd: "",
    sectionIndex: "",
    sectionTitle: "",
    rowRef: "lib/a.ex#h1",
  })

  assert.equal(island.lineStart, undefined)
  assert.equal(island.lineEnd, undefined)
  assert.equal(island.sectionIndex, undefined)
  assert.equal(island.sectionTitle, undefined)
})

test("parses and validates grouped hunk attrs JSON", () => {
  const attrs = [
    {
      file_path: "lib/a.ex",
      row_ref: "lib/a.ex#h1",
      hunk_fingerprint: "abc",
      hunk_index: 1,
      line_start: 1,
      line_end: 2,
    },
    {
      file_path: "lib/a.ex",
      row_ref: "lib/a.ex#h2",
      hunk_fingerprint: "def",
      hunk_index: 2,
      line_start: null,
      line_end: null,
    },
  ]

  const island = HunkIslandDataset.parse({
    ...baseDataset,
    hunkAttrs: JSON.stringify(attrs),
  })

  assert.equal(island.hunkAttrs.length, 2)
  assert.equal(island.hunkAttrs[1].hunk_index, 2)
})

test("rejects malformed hunk attrs JSON", () => {
  assert.throws(() =>
    HunkIslandDataset.parse({ ...baseDataset, hunkAttrs: "{not json" })
  )
})

test("builds the mark-viewed payload from the parsed island", () => {
  const island = HunkIslandDataset.parse(baseDataset)
  const payload = hunkViewPayload(island)

  // hunk_attrs stays undefined for ungrouped hunks; JSON serialization in
  // pushEvent drops undefined keys from the wire payload.
  assert.deepEqual(JSON.parse(JSON.stringify(payload)), {
    file_path: "lib/a.ex",
    row_ref: "lib/a.ex#h1",
    hunk_fingerprint: "abc123",
    hunk_id: "packet-section-0-row-0--hunk-lib-a-ex-1",
    hunk_index: 1,
    line_start: 1,
    line_end: 2,
    section_index: 0,
    section_title: "Main change",
  })
})

test("re-encodes grouped hunk attrs for the wire", () => {
  const attrs = [
    {
      file_path: "lib/a.ex",
      row_ref: "lib/a.ex#h1",
      hunk_fingerprint: "abc",
      hunk_index: 1,
    },
  ]

  const island = HunkIslandDataset.parse({
    ...baseDataset,
    hunkAttrs: JSON.stringify(attrs),
  })
  const payload = hunkViewPayload(island)

  assert.equal(typeof payload.hunk_attrs, "string")
  assert.deepEqual(JSON.parse(payload.hunk_attrs), attrs)
})
