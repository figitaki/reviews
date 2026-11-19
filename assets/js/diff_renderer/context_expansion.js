import { parsePatchFiles } from "@pierre/diffs"

const files = new Map()
const MAX_CACHED_FILES = 4
const CONTEXT_STEP = 20

export function loadFileContext(url) {
  if (files.has(url)) return files.get(url)
  const pending = fetch(url, { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(20000) })
    .then(async response => {
      const body = await response.json()
      if (!response.ok) {
        const error = new Error(body.error || "Could not load context. Try again.")
        error.unavailable = [409, 413, 422].includes(response.status)
        throw error
      }
      const full = parsePatchFiles(body.raw_diff).flatMap(patch => patch.files)[0]
      if (!full || typeof body.old !== "string" || typeof body.new !== "string") {
        throw new Error("Could not read file context.")
      }
      const oldLines = body.old.match(/[^\n]*\n|[^\n]+$/g) || []
      const newLines = body.new.match(/[^\n]*\n|[^\n]+$/g) || []
      return { oldLines, newLines, regions: unchangedRegions(full, oldLines.length, newLines.length) }
    })
    .catch(error => { if (!error.unavailable && files.get(url) === pending) files.delete(url); throw error })
  files.set(url, pending)
  if (files.size > MAX_CACHED_FILES) files.delete(files.keys().next().value)
  return pending
}

// Only canonical unchanged regions may be expanded. In packet slices, the
// omitted code can include other changes; never present those as context.
export function unchangedRegions(full, oldLength, newLength) {
  const regions = []
  let old = 0, next = 0
  for (const hunk of full.hunks) {
    for (const part of hunk.hunkContent) {
      if (part.type !== "change") continue
      const oldStart = start(hunk, "deletion") + part.deletionLineIndex - hunk.deletionLineIndex
      const newStart = start(hunk, "addition") + part.additionLineIndex - hunk.additionLineIndex
      if (oldStart - old === newStart - next) regions.push({ old, next, count: oldStart - old })
      old = oldStart + part.deletions
      next = newStart + part.additions
    }
  }
  if (oldLength - old === newLength - next) regions.push({ old, next, count: oldLength - old })
  return regions
}

const start = (hunk, side) => hunk[`${side}Start`] - (hunk[`${side}Count`] > 0 ? 1 : 0)

export function availableContext(diff, source, index, direction) {
  const hunk = diff.hunks[index]
  if (!hunk) return 0
  const above = direction === "above"
  const old = start(hunk, "deletion") + (above ? 0 : hunk.deletionCount)
  const next = start(hunk, "addition") + (above ? 0 : hunk.additionCount)
  const neighbor = diff.hunks[index + (above ? -1 : 1)]
  const gap = neighbor
    ? above ? old - start(neighbor, "deletion") - neighbor.deletionCount : start(neighbor, "deletion") - old
    : Infinity
  if (!source) return Math.max(0, Math.min(gap, above ? Math.min(old, next) : CONTEXT_STEP))
  const region = source.regions.find(region => {
    const offset = old - region.old
    return offset === next - region.next && offset >= 0 && offset <= region.count &&
      (above ? offset > 0 : offset < region.count)
  })
  if (!region) return 0
  const limit = Math.max(0, Math.min(CONTEXT_STEP, gap, above ? old - region.old : region.count - (old - region.old)))
  let count = 0
  while (count < limit) {
    const delta = above ? -count - 1 : count
    if (source.oldLines[old + delta] !== source.newLines[next + delta]) break
    count++
  }
  return count
}

export function expandContext(rawDiff, diff, source, index, direction) {
  const count = Math.min(CONTEXT_STEP, availableContext(diff, source, index, direction))
  if (!count) return rawDiff
  const hunk = diff.hunks[index]
  const above = direction === "above"
  const offset = start(hunk, "deletion") + (above ? -count : hunk.deletionCount)
  const context = source.oldLines.slice(offset, offset + count).map(line =>
    ` ${line}${line.endsWith("\n") ? "" : "\n\\ No newline at end of file\n"}`
  ).join("")
  const blocks = rawDiff.split(/(?=^@@ -\d)/m)
  const block = blocks[index + 1]
  const newline = block.indexOf("\n")
  const header = block.slice(0, newline).replace(
    /^@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@/,
    `@@ -${start(hunk, "deletion") + 1 - (above ? count : 0)},${hunk.deletionCount + count} +${start(hunk, "addition") + 1 - (above ? count : 0)},${hunk.additionCount + count} @@`
  )
  const body = block.slice(newline + 1)
  blocks[index + 1] = `${header}\n${above ? context + body : body + context}`
  return blocks.join("")
}
