import MarkdownIt from "markdown-it"

// Packet prose is untrusted. Never interpret authored HTML as application markup.
const markdown = new MarkdownIt({ html: false, linkify: true })
markdown.validateLink = url => {
  // Markdown-it normalizes destinations before validation. Check encoded
  // backslashes too; a browser must not reinterpret them as a host separator.
  if (/%(?:0[0-9a-f]|1[0-9a-f]|5c|7f)/i.test(url) || url.startsWith("//")) return false
  return /^(?:https?:|mailto:)/i.test(url) || !/^[^/?#]*:/.test(url)
}

const renderImage = markdown.renderer.rules.image
markdown.renderer.rules.image = (tokens, index, options, env, renderer) => {
  const token = tokens[index]
  // Only bundled SVG basenames: no hosts, subdirectories, traversal, escapes,
  // query strings or fragments. Remote packet images must never make requests.
  if (!/^\/images\/[a-zA-Z0-9][a-zA-Z0-9_-]*\.svg$/.test(token.attrGet("src") || "")) {
    return markdown.utils.escapeHtml(renderer.renderInlineAsText(token.children, options, env))
  }
  return renderImage(tokens, index, options, env, renderer)
}

for (const type of ["fence", "code_block"]) {
  const render = markdown.renderer.rules[type]
  markdown.renderer.rules[type] = (tokens, index, options, env, renderer) => {
    const html = render(tokens, index, options, env, renderer)
    return tokens[index].meta?.reviewChanged
      ? html.replace("<pre>", '<pre class="review-markdown-change">')
      : html
  }
}

export function renderMarkdown(source, changedLines = [], { preview = false } = {}) {
  const tokens = markdown.parse(source || "", {})
  if (preview) {
    // Keep document headings below the review section (h2) and side label (h3).
    const levels = [...new Set(tokens.filter(token => token.type === "heading_open").map(token => token.tag))].sort()
    for (const token of tokens) {
      if (token.type === "heading_open" || token.type === "heading_close") {
        const heading = token.tag
        token.tag = "div"
        if (token.type === "heading_open") {
          token.attrSet("role", "heading")
          token.attrSet("aria-level", String(Math.min(6, 4 + levels.indexOf(heading))))
          token.attrSet("data-markdown-heading", heading)
        }
      }
      let relativeLink = false
      for (const child of token.children || []) {
        if (child.type === "link_open") {
          relativeLink = !/^(?:https?:|mailto:)/i.test(child.attrGet("href") || "")
          if (relativeLink) {
            child.tag = "span"
            child.attrs = [["title", "Repository-relative link. See the path in Source."], ["class", "review-markdown-relative-link"]]
          } else {
            child.attrSet("target", "_blank")
            child.attrSet("rel", "noopener noreferrer")
          }
        } else if (child.type === "link_close" && relativeLink) {
          child.tag = "span"
          relativeLink = false
        }
      }
    }
  }
  const sortedChanges = [...changedLines].sort((a, b) => a - b)
  for (const token of tokens) {
    const block = (token.level === 0 && !["bullet_list_open", "ordered_list_open"].includes(token.type)) ||
      (token.level === 1 && token.type === "list_item_open")
    if (!block || !token.map) continue
    // Find the first change at or after this block's start, without rescanning
    // every changed line for every block in a fully added document.
    let low = 0
    let high = sortedChanges.length
    while (low < high) {
      const mid = Math.floor((low + high) / 2)
      if (sortedChanges[mid] < token.map[0]) low = mid + 1
      else high = mid
    }
    if (low < sortedChanges.length && sortedChanges[low] < token.map[1]) {
      if (["fence", "code_block"].includes(token.type)) token.meta = { reviewChanged: true }
      else token.attrJoin("class", "review-markdown-change")
    }
  }
  return markdown.renderer.render(tokens, markdown.options, {})
}

export const isMarkdown = (path) => /\.(md|markdown|mdown|mkd)$/i.test(path || "")

// Keep separate hunks separate: omitted lines may contain fences, lists or tables.
export function markdownPatchExcerpts(patch) {
  const excerpts = []
  let current = null
  let oldRemaining = 0
  let newRemaining = 0
  for (const line of (patch || "").split("\n")) {
    const header = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/.exec(line)
    if (header) {
      current = { oldStart: Number(header[1]), newStart: Number(header[3]), before: [], after: [], beforeChanges: [], afterChanges: [] }
      oldRemaining = Number(header[2] ?? 1)
      newRemaining = Number(header[4] ?? 1)
      excerpts.push(current)
    } else if (current && (oldRemaining || newRemaining)) {
      if (line.startsWith(" ") && oldRemaining && newRemaining) {
        current.before.push(line.slice(1)); current.after.push(line.slice(1))
        oldRemaining--; newRemaining--
      } else if (line.startsWith("-") && oldRemaining) {
        current.beforeChanges.push(current.before.length)
        current.before.push(line.slice(1)); oldRemaining--
      } else if (line.startsWith("+") && newRemaining) {
        current.afterChanges.push(current.after.length)
        current.after.push(line.slice(1)); newRemaining--
      }
    }
  }
  return excerpts.map((excerpt) => ({ ...excerpt, before: excerpt.before.join("\n"), after: excerpt.after.join("\n") }))
}
