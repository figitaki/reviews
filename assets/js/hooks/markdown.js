import { renderMarkdown } from "../lib/markdown.js"
import { renderMermaidBlocks } from "../lib/mermaid_blocks.js"

export default {
  mounted() { this.renderMarkdown() },
  updated() { this.renderMarkdown() },
  renderMarkdown() {
    const output = this.el.querySelector("[data-markdown-output]")
    if (!output) return
    output.innerHTML = renderMarkdown(this.el.dataset.markdown)
    renderMermaidBlocks(output)
  },
}
