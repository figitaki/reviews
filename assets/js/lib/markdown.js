import MarkdownIt from "markdown-it"

// Packet prose is untrusted. Never interpret authored HTML as application markup.
const markdown = new MarkdownIt({ html: false, linkify: true })
markdown.validateLink = url => {
  if (/[\u0000-\u0020\u007f\\]/.test(url) || url.startsWith("//")) return false
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

export const renderMarkdown = source => markdown.render(source || "")

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
      current = { oldStart: Number(header[1]), newStart: Number(header[3]), before: [], after: [] }
      oldRemaining = Number(header[2] ?? 1)
      newRemaining = Number(header[4] ?? 1)
      excerpts.push(current)
    } else if (current && (oldRemaining || newRemaining)) {
      if (line.startsWith(" ") && oldRemaining && newRemaining) {
        current.before.push(line.slice(1)); current.after.push(line.slice(1))
        oldRemaining--; newRemaining--
      } else if (line.startsWith("-") && oldRemaining) {
        current.before.push(line.slice(1)); oldRemaining--
      } else if (line.startsWith("+") && newRemaining) {
        current.after.push(line.slice(1)); newRemaining--
      }
    }
  }
  return excerpts.map((excerpt) => ({ ...excerpt, before: excerpt.before.join("\n"), after: excerpt.after.join("\n") }))
}
