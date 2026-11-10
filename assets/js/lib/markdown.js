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
