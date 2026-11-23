// Draws ```mermaid fences that renderMarkdown left as escaped <pre><code>.
// The source <pre> stays in the DOM: it is shown until the diagram is drawn,
// shown again if drawing fails, and read again when the theme changes.
let renderer
let diagramCount = 0
let watchingTheme = false

const loadRenderer = () => {
  renderer ||= new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = document.querySelector('meta[name="mermaid-renderer"]')?.content || ""
    script.onload = () => resolve(window.ReviewsMermaid)
    script.onerror = () => {
      renderer = null
      reject(new Error("The diagram renderer did not load."))
    }
    document.head.append(script)
  })
  return renderer
}

const darkTheme = () => {
  const theme = document.documentElement.getAttribute("data-theme")
  return theme ? theme === "dark" : window.matchMedia?.("(prefers-color-scheme: dark)").matches === true
}

const showOutput = (figure, node) => {
  figure.querySelector(".review-mermaid-diagram, .review-mermaid-error")?.remove()
  figure.append(node)
}

async function drawFigure(figure) {
  const source = figure.querySelector("pre")
  try {
    const { renderDiagram } = await loadRenderer()
    const fragment = await renderDiagram(`review-mermaid-${++diagramCount}`, source.textContent, { dark: darkTheme() })
    const svg = fragment.querySelector("svg")
    if (!svg) throw new Error("The diagram is empty.")
    const width = Number((svg.getAttribute("viewBox") || "").split(/[\s,]+/)[2])
    if (width > 0) svg.setAttribute("width", String(width))
    svg.style.maxWidth = "none"
    const diagram = document.createElement("div")
    diagram.className = "review-mermaid-diagram"
    diagram.append(svg)
    showOutput(figure, diagram)
    source.hidden = true
  } catch (error) {
    const message = document.createElement("figcaption")
    message.className = "review-mermaid-error"
    const detail = String(error?.message || error).split("\n")[0].slice(0, 200)
    message.textContent = `This diagram could not be drawn. ${detail}`
    showOutput(figure, message)
    source.hidden = false
  }
}

const redrawAll = () => {
  for (const figure of document.querySelectorAll("figure.review-mermaid")) drawFigure(figure)
}

function watchTheme() {
  if (watchingTheme) return
  watchingTheme = true
  new MutationObserver(redrawAll).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] })
  window.matchMedia?.("(prefers-color-scheme: dark)").addEventListener?.("change", redrawAll)
}

export function renderMermaidBlocks(root) {
  const fences = root.querySelectorAll("pre > code.language-mermaid")
  if (!fences.length) return Promise.resolve()
  watchTheme()
  return Promise.all([...fences].map(code => {
    const pre = code.parentElement
    const figure = document.createElement("figure")
    figure.className = "review-mermaid"
    pre.replaceWith(figure)
    figure.append(pre)
    return drawFigure(figure)
  }))
}
