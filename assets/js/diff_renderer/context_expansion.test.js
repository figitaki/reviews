import { expect, test } from "bun:test"
import { parsePatchFiles } from "@pierre/diffs"
import { availableContext, expandContext, loadFileContext, unchangedRegions } from "./context_expansion.js"

const header = "diff --git a/a.js b/a.js\n--- a/a.js\n+++ b/a.js\n"
const chunk = n => `@@ -${n - 3},7 +${n - 3},7 @@\n line ${n - 3}\n line ${n - 2}\n line ${n - 1}\n-line ${n}\n+changed ${n}\n line ${n + 1}\n line ${n + 2}\n line ${n + 3}\n`
const raw = header + chunk(30) + chunk(90)
const parse = patch => parsePatchFiles(patch)[0].files[0]
const oldLines = Array.from({ length: 120 }, (_, i) => `line ${i + 1}\n`)
const newLines = oldLines.map((line, i) => [29, 89].includes(i) ? `changed ${i + 1}\n` : line)
const source = { oldLines, newLines, regions: unchangedRegions(parse(raw), 120, 120) }

test("expands above and below in steps, keeping source line numbers and changes", () => {
  const above = expandContext(raw, parse(raw), source, 0, "above")
  expect(above).toContain("@@ -7,27 +7,27 @@")
  expect(above).toContain(" line 7\n")
  expect(above).not.toContain(" line 6\n")
  const below = expandContext(above, parse(above), source, 0, "below")
  expect(below).toContain("@@ -7,47 +7,47 @@")
  expect(below).toContain(" line 53\n")
  expect(parse(below).hunks.map(hunk => hunk.additionLines)).toEqual([1, 1])
})

test("stops at file boundaries and neighboring hunks without duplicating lines", () => {
  let patch = raw
  for (let i = 0; i < 5; i++) patch = expandContext(patch, parse(patch), source, 0, "above")
  expect(parse(patch).hunks[0].additionStart).toBe(1)
  expect(availableContext(parse(patch), source, 0, "above")).toBe(0)
  for (let i = 0; i < 5; i++) patch = expandContext(patch, parse(patch), source, 0, "below")
  expect(parse(patch).hunks[0].additionCount).toBe(86)
  expect(patch.match(/ line 87\n/g)).toHaveLength(1)
  for (let i = 0; i < 5; i++) patch = expandContext(patch, parse(patch), source, 1, "below")
  expect(patch).toContain(" line 120\n")
  expect(availableContext(parse(patch), source, 1, "below")).toBe(0)
})

test("packet slices cannot turn another change into unchanged context", () => {
  let slice = header + chunk(90)
  for (let i = 0; i < 8; i++) slice = expandContext(slice, parse(slice), source, 0, "above")
  expect(parse(slice).hunks[0].additionStart).toBe(31)
  expect(slice).not.toContain(" line 30\n")
  let first = header + chunk(30)
  for (let i = 0; i < 8; i++) first = expandContext(first, parse(first), source, 0, "below")
  expect(first).toContain(" line 89\n")
  expect(first).not.toContain(" line 90\n")
})

test("keeps asymmetric line numbers after an insertion and a missing final newline", () => {
  const patch = header + "@@ -2 +2,2 @@\n line 2\n+inserted\n"
  const old = ["line 1\n", "line 2\n", "last"]
  const next = ["line 1\n", "line 2\n", "inserted\n", "last"]
  const files = { oldLines: old, newLines: next, regions: unchangedRegions(parse(patch), 3, 4) }
  const expanded = expandContext(patch, parse(patch), files, 0, "below")
  expect(expanded).toContain("@@ -2,2 +2,3 @@")
  expect(expanded).toEndWith(" last\n\\ No newline at end of file\n")
  expect(parse(expanded).hunks[0].noEOFCRAdditions).toBe(true)
})

test("rejects mismatched surrounding source instead of showing it as unchanged", () => {
  const mismatched = { ...source, newLines: newLines.map((line, i) => i === 25 ? "different\n" : line) }
  expect(expandContext(raw, parse(raw), mismatched, 0, "above")).toBe(raw)
})

test("shares in-flight and cached reads between islands, and retries failures", async () => {
  const original = globalThis.fetch
  let requests = 0
  globalThis.fetch = async () => {
    requests++
    return Response.json({ old: oldLines.join(""), new: newLines.join(""), raw_diff: raw })
  }
  try {
    const first = loadFileContext("/context/shared")
    const second = loadFileContext("/context/shared")
    const contexts = await Promise.all([first, second])
    expect(contexts.map(context => context.oldLines.length)).toEqual([120, 120])
    await loadFileContext("/context/shared")
    expect(requests).toBe(1)
    globalThis.fetch = async () => Response.json({ error: "Unavailable" }, { status: 502 })
    await expect(loadFileContext("/context/retry")).rejects.toThrow("Unavailable")
    globalThis.fetch = async () => Response.json({ old: oldLines.join(""), new: newLines.join(""), raw_diff: raw })
    expect((await loadFileContext("/context/retry")).newLines).toHaveLength(120)
  } finally { globalThis.fetch = original }
})

test("expands zero-context insertions and deletions with Git's zero-count coordinates", () => {
  for (const inserted of [true, false]) {
    const patch = header + (inserted ? "@@ -2,0 +3 @@\n+inserted\n" : "@@ -3 +2,0 @@\n-inserted\n")
    const short = ["one\n", "two\n", "three\n"]
    const long = ["one\n", "two\n", "inserted\n", "three\n"]
    const oldLines = inserted ? short : long
    const newLines = inserted ? long : short
    const source = {oldLines, newLines, regions: unchangedRegions(parse(patch), oldLines.length, newLines.length)}
    const expanded = expandContext(patch, parse(patch), source, 0, "above")
    expect(parse(expanded).hunks[0].deletionStart).toBe(1)
    expect(parse(expanded).hunks[0].additionStart).toBe(1)
    const complete = expandContext(expanded, parse(expanded), source, 0, "below")
    expect(parse(complete).deletionLines).toEqual(oldLines)
    expect(parse(complete).additionLines).toEqual(newLines)
  }
})

test("unavailable snapshots share a cached failure instead of repeating source requests", async () => {
  const original = globalThis.fetch
  let requests = 0
  globalThis.fetch = async () => {
    requests++
    return Response.json({error: "No snapshot"}, {status: 409})
  }
  try {
    await expect(loadFileContext("/context/unavailable")).rejects.toThrow("No snapshot")
    await expect(loadFileContext("/context/unavailable")).rejects.toThrow("No snapshot")
    expect(requests).toBe(1)
  } finally { globalThis.fetch = original }
})
