import { el } from "./dom.js"
import { markdownPatchExcerpts, renderMarkdown } from "../lib/markdown.js"

export function discussionCount(threads = [], hunks = []) {
  return threads.filter(thread => hunks.some(hunk => {
    const side = thread.side === "old" ? "deletion" : "addition"
    const line = thread.anchor.line_number_hint
    return line >= hunk[`${side}Start`] && line < hunk[`${side}Start`] + hunk[`${side}Count`]
  })).length
}

// A fence may follow blockquote or list markers, or sit indented inside a list item.
const FENCE = /^(?: {0,3}>\s?| {0,3}(?:[-+*]|\d{1,9}[.)])\s+)*\s*(`{3,}|~{3,})(.*)$/

// A patch cannot tell us the surrounding structure of an arbitrary excerpt.
// Refuse visibly ambiguous fragments rather than inventing a document structure.
export function markdownPreviewState(patch, fileDiff) {
  if (new TextEncoder().encode(patch).length >= 200 * 1024 ||
      Math.max(fileDiff?.splitLineCount || 0, fileDiff?.unifiedLineCount || 0) >= 1500) {
    return { reason: "Large Markdown file. Source keeps scrolling responsive." }
  }
  const excerpts = markdownPatchExcerpts(patch)
  const complete = ["new", "deleted"].includes(fileDiff?.type)
  if (!complete) {
    for (const excerpt of excerpts) {
      for (const [side, start] of [["before", excerpt.oldStart], ["after", excerpt.newStart]]) {
        const text = excerpt[side]
        const lines = text.split("\n")
        const first = lines.find(line => line.trim()) || ""
        // Fences in a partial excerpt may close a fence opened in omitted text.
        // The same applies to table rows without a header and list continuations.
        let fence = null
        let sawFence = false
        // Fenced lines are blanked so pipes in code are not read as table rows.
        const prose = lines.map(line => {
          const marker = FENCE.exec(line)
          if (marker) sawFence = true
          if (!fence) {
            if (!marker) return line
            fence = marker[1]
          } else if (marker && marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) {
            fence = null
          }
          return ""
        })
        const tableFragment = prose.some((line, index) =>
          line.includes("|") && !(prose[index - 1] || "").includes("|") &&
          !/^ {0,3}\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$/.test(prose[index + 1] || ""))
        // Two or more leading spaces can continue a list item whose marker is omitted.
        if (fence || tableFragment || (start > 1 && (/^(?: {2,}|\t)/.test(first) || sawFence))) {
          return { reason: "Surrounding Markdown is missing. Use Source for this excerpt." }
        }
      }
    }
  }
  return { excerpts, complete, reason: null }
}

export function previewNotice(preview, state) {
  if (state.reason) return state.reason
  if (!preview) return "Exact changes and discussions."
  return state.complete ? "Complete document. Comments are in Source." :
    "Patch excerpts; omitted context may affect formatting. Comments are in Source."
}

export function markdownPreview(state, diffStyle = "split") {
  const preview = el("div", { className: "review-markdown-preview", dataset: { diffStyle } })
  for (const excerpt of state.excerpts) {
    const pair = el("div", { className: "review-markdown-pair" })
    for (const [side, label, start] of [["before", "Before", excerpt.oldStart], ["after", "After", excerpt.newStart]]) {
      if (state.complete && !excerpt[side]) continue
      const body = el("div", { className: "review-rich-markdown" })
      body.innerHTML = renderMarkdown(excerpt[side], state.complete ? [] : excerpt[`${side}Changes`], { preview: true })
      if (!excerpt[side]) body.textContent = "No lines in this excerpt."
      for (const block of body.querySelectorAll(".review-markdown-change")) {
        const badge = el(block.tagName === "TABLE" ? "caption" : "span",
          { className: "review-markdown-change-label" }, side === "before" ? "− Changed" : "+ Changed")
        block.prepend(badge)
      }
      const sideLabel = state.complete ? (side === "after" ? "New file" : "Deleted file") : `${label} · L${start}`
      pair.append(el("section", { className: `review-markdown-side is-${side}`, "aria-label": state.complete ? sideLabel : `${label}, line ${start}` }, [
        el("h3", { className: "review-markdown-side-label" }, sideLabel), body,
      ]))
    }
    preview.append(pair)
  }
  return preview
}
