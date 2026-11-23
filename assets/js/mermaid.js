// Lazy entry: the page loads this file only when packet prose has a mermaid fence.
import mermaid from "mermaid"
import DOMPurify from "dompurify"

// Directives (%%{init}%%) and frontmatter config must not change these keys.
const SECURE_KEYS = [
  "secure", "securityLevel", "startOnLoad", "maxTextSize", "suppressErrorRendering", "maxEdges",
  "htmlLabels", "theme", "themeVariables", "themeCSS", "darkMode", "fontFamily", "altFontFamily",
  "arrowMarkerAbsolute",
]

// CSS functions and at-rules that make the browser fetch a resource. Packet
// content must never make requests, so a diagram may only reference its own
// fragments (url(#marker)).
const FETCHING_FUNCTION = /([a-z0-9_-]+)\(\s*(['"]?)\s*(.?)/gi
const FETCHING_NAMES = new Set(["url", "image", "image-set", "cross-fade", "element", "src", "paint"])
const blockFetches = css =>
  css
    .replace(/\\/g, "")
    .replace(/@(import|font-face|namespace)\b/gi, "@blocked")
    .replace(FETCHING_FUNCTION, (match, name, quote, first) => {
      const bare = name.toLowerCase().replace(/^-(webkit|moz|o|ms)-/, "")
      if (!FETCHING_NAMES.has(bare) || (bare === "url" && first === "#")) return match
      return `blocked(${quote}${first}`
    })

const purifier = DOMPurify(window)
purifier.addHook("uponSanitizeElement", node => {
  if (node.nodeName?.toLowerCase() === "style") node.textContent = blockFetches(node.textContent)
})
purifier.addHook("afterSanitizeAttributes", node => {
  for (const attribute of [...(node.attributes || [])]) {
    const value = blockFetches(attribute.value)
    if (value !== attribute.value) node.setAttribute(attribute.name, value)
  }
})

export const sanitizeSvg = svg =>
  purifier.sanitize(svg, {
    USE_PROFILES: { svg: true, svgFilters: true },
    FORBID_TAGS: ["a", "foreignObject", "image", "feImage"],
    FORBID_ATTR: ["href", "xlink:href"],
    RETURN_DOM_FRAGMENT: true,
  })

let queue = Promise.resolve()

// Returns a sanitized DocumentFragment holding the diagram's <svg>.
export function renderDiagram(id, source, { dark }) {
  const run = async () => {
    mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      htmlLabels: false,
      suppressErrorRendering: true,
      theme: dark ? "dark" : "default",
      fontFamily: "ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif",
      secure: SECURE_KEYS,
    })
    const { svg } = await mermaid.render(id, source)
    return sanitizeSvg(svg)
  }
  // mermaid's configuration is global: render one diagram at a time.
  const result = queue.then(run)
  queue = result.catch(() => {})
  return result
}

window.ReviewsMermaid = { renderDiagram }
