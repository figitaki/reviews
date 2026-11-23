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
const FETCHING_FUNCTION = /([a-z0-9_-]+)\((?=\s*['"]?\s*(.?))/gi
const FETCHING_AT_RULE = /@(import|font-face|namespace)\b/gi
const FETCHING_NAMES = new Set(["url", "image", "image-set", "cross-fade", "element", "src", "paint"])
const fetches = (name, first) => {
  const bare = name.toLowerCase().replace(/^-(webkit|moz|o|ms)-/, "")
  return FETCHING_NAMES.has(bare) && !(bare === "url" && first === "#")
}
const codePoint = (digits, radix) => {
  const value = Number.parseInt(digits, radix)
  return String.fromCodePoint(value > 0 && value <= 0x10ffff ? value : 0xfffd)
}
const decodeCssEscapes = css =>
  css.replace(/\\(?:([0-9a-f]{1,6})\s?|(.))/gis, (_, hex, char) => hex ? codePoint(hex, 16) : char)
// mermaid decodes entities (#40; &#x28; &lpar;) in diagram text, so check the decoded form too.
const decodeEntities = text =>
  text
    .replace(/&?#x([0-9a-f]{1,6});/gi, (_, hex) => codePoint(hex, 16))
    .replace(/&?#(\d{1,7});/g, (_, decimal) => codePoint(decimal, 10))
    .replace(/&?#?(lpar|rpar|colon|sol|bsol);/gi, (_, name) => ({ lpar: "(", rpar: ")", colon: ":", sol: "/", bsol: "\\" })[name.toLowerCase()])
const blockFetches = css =>
  decodeCssEscapes(css)
    .replace(FETCHING_AT_RULE, "@blocked")
    .replace(FETCHING_FUNCTION, (match, name, first) => fetches(name, first) ? "blocked(" : match)
const hasFetch = css =>
  /@(import|font-face|namespace)\b/i.test(css) || [...css.matchAll(FETCHING_FUNCTION)].some(([, name, first]) => fetches(name, first))

// mermaid's image shape loads its URL with `new Image()` while it lays out.
class InertImage {
  set src(_url) {}
  decode() { return Promise.reject(new Error("Diagrams cannot load images.")) }
}

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
    // mermaid puts classDef and style CSS into the live page while it lays out,
    // so CSS that fetches must be refused before render, not only sanitized after.
    if (hasFetch(decodeCssEscapes(source)) || hasFetch(decodeCssEscapes(decodeEntities(source)))) throw new Error("Diagrams cannot load images, fonts or other files.")
    const realImage = globalThis.Image
    globalThis.Image = InertImage
    try {
      const { svg } = await mermaid.render(id, source)
      return sanitizeSvg(svg)
    } finally {
      globalThis.Image = realImage
    }
  }
  // mermaid's configuration is global: render one diagram at a time.
  const result = queue.then(run)
  queue = result.catch(() => {})
  return result
}

window.ReviewsMermaid = { renderDiagram }
