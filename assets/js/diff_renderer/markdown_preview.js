import { el } from "./dom.js"
import { markdownPatchExcerpts, renderMarkdown } from "../lib/markdown.js"

export function previewNotice(threads = [], hunks = []) {
  const threadCount = threads.filter(thread => hunks.some(hunk => {
    const side = thread.side === "old" ? "deletion" : "addition"
    const line = thread.anchor.line_number_hint
    return line >= hunk[`${side}Start`] && line < hunk[`${side}Start`] + hunk[`${side}Count`]
  })).length
  const notice = "Excerpts only. Source shows changes and comments."
  if (threadCount === 0) return notice
  return `${notice} ${threadCount} ${threadCount === 1 ? "discussion" : "discussions"}.`
}

export function markdownPreview(patch, diffStyle = "split") {
  const preview = el("div", { className: "review-markdown-preview", dataset: { diffStyle } })
  for (const excerpt of markdownPatchExcerpts(patch)) {
    const pair = el("div", { className: "review-markdown-pair" })
    for (const [side, label, start] of [["before", "Before", excerpt.oldStart], ["after", "After", excerpt.newStart]]) {
      const body = el("div", { className: "review-rich-markdown" })
      body.innerHTML = renderMarkdown(excerpt[side], excerpt[`${side}Changes`])
      if (!excerpt[side]) body.textContent = "Empty."
      pair.append(el("section", { className: `review-markdown-side is-${side}`, "aria-label": `${label}, line ${start}` }, [
        el("h3", { className: "review-markdown-side-label" }, `${label} · L${start}`), body,
      ]))
    }
    preview.append(pair)
  }
  return preview
}
