import { renderMarkdown } from "../lib/markdown.js"
import { renderMermaidBlocks } from "../lib/mermaid_blocks.js"

export default {
  mounted() { this.renderMarkdown() },
  updated() { this.renderMarkdown() },
  renderMarkdown() {
    const output = this.el.querySelector("[data-markdown-output]")
    if (!output || this.rendered === this.el.dataset.markdown) return
    this.rendered = this.el.dataset.markdown
    output.innerHTML = renderMarkdown(this.rendered)
    renderMermaidBlocks(output)
  },
}
