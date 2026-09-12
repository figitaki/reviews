import { renderMarkdown } from "../lib/markdown.js"

export default {
  mounted() { this.renderMarkdown() },
  updated() { this.renderMarkdown() },
  renderMarkdown() {
    this.el.querySelector("[data-markdown-output]").innerHTML = renderMarkdown(this.el.dataset.markdown)
  },
}
