import { renderMarkdown } from "../lib/markdown.js"

export default {
  mounted() { this.renderMarkdown() },
  updated() { this.renderMarkdown() },
  renderMarkdown() {
    const output = this.el.querySelector("[data-markdown-output]")
    if (output) output.innerHTML = renderMarkdown(this.el.dataset.markdown)
  },
}
