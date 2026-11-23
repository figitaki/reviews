import { beforeAll, beforeEach, expect, test } from "bun:test"
import { JSDOM } from "jsdom"

let MarkdownHook
let sanitizeSvg

beforeAll(async () => {
  const { window } = new JSDOM("<!doctype html><head></head><body></body>", { url: "https://reviews.test/r/demo", pretendToBeVisual: true })
  for (const key of Object.getOwnPropertyNames(window)) {
    const own = Object.getOwnPropertyDescriptor(globalThis, key)
    if (globalThis[key] === undefined && (!own || own.writable)) globalThis[key] = window[key]
  }
  globalThis.window = window
  globalThis.document = window.document
  // elkjs (bundled by mermaid) reads builtins from the window object.
  for (const key of ["Math", "Map", "Set", "Object", "Array", "String", "Number", "Error", "Date", "JSON", "Symbol", "Promise", "RegExp"]) {
    window[key] = globalThis[key]
  }
  // jsdom has no layout; give text a size so mermaid can place it.
  for (const name of ["SVGElement", "SVGGraphicsElement", "SVGTextContentElement", "SVGTextElement", "SVGTSpanElement"]) {
    if (!window[name]) continue
    window[name].prototype.getBBox = function () { return { x: 0, y: 0, width: 8 * (this.textContent.length || 1), height: 16 } }
    window[name].prototype.getComputedTextLength = function () { return 8 * (this.textContent.length || 1) }
  }
  const meta = document.createElement("meta")
  meta.name = "mermaid-renderer"
  meta.content = "/assets/js/mermaid.js"
  document.head.append(meta)
  // Stand in for the browser loading the lazy script named by the meta tag.
  const append = document.head.append.bind(document.head)
  document.head.append = (node) => {
    if (node.tagName !== "SCRIPT") return append(node)
    expect(node.src).toEndWith("/assets/js/mermaid.js")
    import("../mermaid.js").then(() => node.onload())
  }
  ;({ sanitizeSvg } = await import("../mermaid.js"))
  MarkdownHook = (await import("../hooks/markdown.js")).default
})

beforeEach(() => { document.body.innerHTML = "" })

async function mountPacketProse(markdown) {
  const el = document.createElement("div")
  el.dataset.markdown = markdown
  el.innerHTML = '<div data-markdown-output></div>'
  document.body.append(el)
  el.hook = { ...MarkdownHook, el }
  el.hook.mounted()
  for (let tries = 0; tries < 200; tries++) {
    const figures = [...el.querySelectorAll("figure.review-mermaid")]
    if (figures.every(figure => figure.querySelector(".review-mermaid-diagram, .review-mermaid-error"))) return el
    await new Promise(resolve => setTimeout(resolve, 10))
  }
  throw new Error("mermaid figures did not settle")
}

// A CSS function that would load something other than a fragment of the SVG itself.
const FETCH = /(?:^|[^a-z0-9_-])(?:url|image|image-set|cross-fade|src)\(\s*['"]?\s*[^#'"\s]/i

function expectNoLiveContent(root, label) {
  expect(root.querySelector("script, img, iframe, object, embed, foreignObject, a, image, use, feImage"), label).toBeNull()
  for (const node of root.querySelectorAll("*")) {
    for (const { name, value } of node.attributes) {
      expect(name, label).not.toMatch(/^on/i)
      expect(value, label).not.toMatch(/javascript:|vbscript:|data:text/i)
      expect(value, label).not.toMatch(FETCH)
    }
  }
  for (const style of root.querySelectorAll("style")) {
    expect(style.textContent, label).not.toMatch(FETCH)
    expect(style.textContent, label).not.toMatch(/@import/i)
  }
}

test("a sequence diagram fence is drawn as an SVG and keeps its source as text", async () => {
  const el = await mountPacketProse("Flow:\n\n```mermaid\nsequenceDiagram\n  Agent->>Reviews: push packet\n  Reviews-->>Agent: link\n```\n")
  const figure = el.querySelector("figure.review-mermaid")
  const svg = figure.querySelector(".review-mermaid-diagram svg")
  expect(svg).not.toBeNull()
  expect(svg.textContent).toContain("push packet")
  expect(svg.style.maxWidth).toBe("none")
  expect(figure.querySelector("pre").hidden).toBe(true)
  expect(figure.querySelector("pre").textContent).toContain("Agent->>Reviews: push packet")
  expect(figure.querySelector(".review-mermaid-error")).toBeNull()
})

test("a fence that does not parse shows its escaped source and a short error", async () => {
  const el = await mountPacketProse("```mermaid\nnot a diagram <img src=x onerror=alert(1)>\n```\n")
  const figure = el.querySelector("figure.review-mermaid")
  expect(figure.querySelector("pre").hidden).toBe(false)
  expect(figure.querySelector("pre").textContent).toContain("<img src=x onerror=alert(1)>")
  expect(figure.querySelector(".review-mermaid-error").textContent).toStartWith("This diagram could not be drawn.")
  expect(figure.querySelector(".review-mermaid-diagram")).toBeNull()
  expectNoLiveContent(el, "parse error")
})

test("mermaid payloads never produce live HTML, scripts, links or remote requests", async () => {
  const init = '%%{init: {"securityLevel": "loose", "htmlLabels": true, "startOnLoad": true, "secure": [], ' +
    '"themeCSS": "svg { background: url(https://tracker.example/a) } @import \\"https://tracker.example/b.css\\";"}}%%'
  const payloads = [
    "graph TD; A[<img src=x onerror=alert(1)>]-->B",
    `${init}\nsequenceDiagram\n  A->>B: <img src=x onerror=alert(1)>\n  Note over A: <script>alert(1)</script>`,
    `${init}\nflowchart TD\n  A["<img src=x onerror=alert(1)>"] --> B\n  click A call alert(1)\n  click B "javascript:alert(1)"`,
    "---\nconfig:\n  securityLevel: loose\n  htmlLabels: true\n---\nsequenceDiagram\n  A->>B: <b onmouseover=alert(1)>x</b>",
    'sequenceDiagram\n  participant A\n  link A: Docs @ javascript:alert(1)\n  links A: {"Evil": "javascript:alert(1)"}\n  A->>A: hi',
    "flowchart LR\n  A[\"<a href='javascript:alert(1)'>x</a>\"] --> B\n  click A href \"javascript:alert(1)\"",
    "flowchart TD\n  A --> B\n  style A fill:url(https://tracker.example/c)",
    "flowchart TD\n  A:::evil --> B\n  classDef evil fill:url(https://tracker.example/d)",
  ]
  for (const payload of payloads) {
    const el = await mountPacketProse(`\`\`\`mermaid\n${payload}\n\`\`\`\n`)
    expect(el.querySelector("figure.review-mermaid pre").textContent).toBe(`${payload}\n`)
    expectNoLiveContent(el, payload)
  }
})

test("the SVG sanitizer removes active content and remote references a renderer could emit", () => {
  const hostile = `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10" onload="alert(1)">
    <style>@import "https://tracker.example/a.css"; .n { fill: url(https://tracker.example/b); } .m { background: u\\72l(https://tracker.example/c); } .k { background: image-set("https://tracker.example/d" 1x); } .ok { marker-end: url(#arrow); }</style>
    <script>alert(1)</script>
    <foreignObject><div xmlns="http://www.w3.org/1999/xhtml"><img src="x" onerror="alert(1)"></div></foreignObject>
    <a href="javascript:alert(1)"><text>link label</text></a>
    <image href="https://tracker.example/e.png"/>
    <use xlink:href="https://tracker.example/f.svg#x"/>
    <filter id="f"><feImage href="https://tracker.example/g.png"/></filter>
    <style>.z { fill: x(url(https://tracker.example/j)); }</style>
    <rect fill="url(https://tracker.example/h#x)" style="fill: url('https://tracker.example/i')" marker-end="url(#arrow)"/>
  </svg>`
  const root = document.createElement("div")
  root.append(sanitizeSvg(hostile))
  expectNoLiveContent(root, "hostile svg")
  expect(root.querySelector("svg text").textContent).toBe("link label")
  expect(root.querySelector("rect").getAttribute("marker-end")).toBe("url(#arrow)")
  expect(root.querySelector("style").textContent).toContain(".ok { marker-end: url(#arrow); }")
})

test("an image shape never loads its URL and shows why the diagram was not drawn", async () => {
  const requested = []
  const SpyImage = class { set src(url) { requested.push(url) } decode() { return Promise.resolve() } }
  globalThis.Image = SpyImage
  const el = await mountPacketProse('```mermaid\nflowchart TD\n  A@{ img: "https://tracker.example/i.png?reviewer", label: "x", w: 60, h: 60 } --> B\n```\n')
  expect(requested).toEqual([])
  expect(globalThis.Image).toBe(SpyImage)
  expect(el.querySelector(".review-mermaid-error").textContent).toContain("Diagrams cannot load images.")
  expectNoLiveContent(el, "image shape")
})

test("diagram CSS that would fetch is refused before mermaid puts it in the page", async () => {
  const liveStyles = []
  const observer = new MutationObserver(records => {
    for (const record of records) {
      for (const node of record.addedNodes) {
        for (const style of node.querySelectorAll?.("style") ?? []) liveStyles.push(style.textContent)
        if (node.nodeName === "STYLE") liveStyles.push(node.textContent)
      }
    }
  })
  observer.observe(document.body, { childList: true, subtree: true })
  const classDef = css => `stateDiagram-v2\n  classDef evil ${css}\n  [*] --> A\n  class A evil`
  const payloads = [
    classDef("mask-image:url(https://tracker.example/m)"),
    classDef("fill:url(https://tracker.example/f#p)"),
    classDef("mask-image:image-set(url(https://tracker.example/s) 1x)"),
    classDef("mask-image:u\\72l(https://tracker.example/e)"),
    classDef("mask-image:url#40;https://tracker.example/n#41;"),
    "classDiagram\n  class A\n  style A fill:x(url(https://tracker.example/w))",
  ]
  for (const payload of payloads) {
    const el = await mountPacketProse(`\`\`\`mermaid\n${payload}\n\`\`\`\n`)
    expect(el.querySelector(".review-mermaid-error").textContent, payload).toContain("cannot load images, fonts or other files")
  }
  await new Promise(resolve => setTimeout(resolve, 0))
  observer.disconnect()
  for (const css of liveStyles) {
    expect(css).not.toMatch(FETCH)
    expect(css).not.toContain("tracker.example")
  }
})

test("a LiveView update with unchanged markdown keeps the drawn diagram", async () => {
  const el = await mountPacketProse("```mermaid\nsequenceDiagram\n  A->>B: hi\n```\n")
  const svg = el.querySelector(".review-mermaid-diagram svg")
  el.hook.updated()
  expect(el.querySelector(".review-mermaid-diagram svg")).toBe(svg)
})
