import { el } from "./dom.js"
import { markdownPatchExcerpts, renderMarkdown } from "../lib/markdown.js"

export function previewNotice(threadCount = 0) {
  const notice = "Rendered patch excerpts. Omitted file content is unavailable. Use Source to review exact changes and add comments."
  if (threadCount === 0) return notice
  const discussions = threadCount === 1 ? "1 discussion is" : `${threadCount} discussions are`
  return `${notice} ${discussions} shown in Source.`
}

export function markdownPreview(patch, diffStyle = "split") {
  const preview = el("div", { className: "review-markdown-preview", dataset: { diffStyle } })
  for (const excerpt of markdownPatchExcerpts(patch)) {
    const pair = el("div", { className: "review-markdown-pair" })
    for (const [side, label, start] of [["before", "Before", excerpt.oldStart], ["after", "After", excerpt.newStart]]) {
      const body = el("div", { className: "review-rich-markdown" })
      body.innerHTML = renderMarkdown(excerpt[side])
      if (!excerpt[side]) body.textContent = "No content on this side."
      pair.append(el("section", { className: `review-markdown-side is-${side}`, "aria-label": `${label}, line ${start}` }, [
        el("h3", { className: "review-markdown-side-label" }, `${label} · from line ${start}`), body,
      ]))
    }
    preview.append(pair)
  }
  return preview
}
