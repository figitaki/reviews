import test from "node:test"
import assert from "node:assert/strict"

import {
  compactHunkPayload,
  hunkUIFromDataset,
  hunkViewLabel,
} from "./hunk_controls.js"

test("parses Pierre header state and event payloads from LiveView data", () => {
  const state = hunkUIFromDataset({
    filePath: "lib/example.ex",
    rowRef: "row-1",
    hunkFingerprint: "fingerprint",
    hunkId: "hunk-1",
    hunkLabel: "hunks 1-2",
    hunkExpanded: "true",
    hunkViewed: "false",
    hunkPartiallyViewed: "true",
    hunkIndex: "1",
    lineStart: "12",
    lineEnd: "18",
    sectionIndex: "0",
    sectionTitle: "State flow",
    signedIn: "true",
  })

  assert.equal(state.expanded, true)
  assert.equal(state.partiallyViewed, true)
  assert.equal(hunkViewLabel(state), "Partially viewed")
  assert.deepEqual(compactHunkPayload(state.payload), {
    file_path: "lib/example.ex",
    row_ref: "row-1",
    hunk_fingerprint: "fingerprint",
    hunk_id: "hunk-1",
    hunk_index: 1,
    line_start: 12,
    line_end: 18,
    section_index: 0,
    section_title: "State flow",
  })
})

test("uses explicit viewed state ahead of aggregate file progress", () => {
  const state = hunkUIFromDataset({
    hunkViewed: "true",
    hunkPartiallyViewed: "false",
    hunkViewState: "2 of 3 viewed",
  })

  assert.equal(hunkViewLabel(state), "Viewed")
})
