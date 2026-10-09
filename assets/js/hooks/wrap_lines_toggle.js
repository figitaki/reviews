// WrapLinesToggle — the header "Wrap lines" button. The state is a browser
// preference (localStorage), mirrored on <html data-wrap-lines>; DiffRenderer
// islands observe that attribute and re-render. The button is
// phx-update="ignore", so LiveView never resets aria-pressed.

import {
  applyWrapLines,
  readWrapLinesPref,
  writeWrapLinesPref,
} from "../lib/line_wrap.js"

const WrapLinesToggle = {
  mounted() {
    this.sync = (value) => {
      this.el.setAttribute("aria-pressed", value ? "true" : "false")
      this.el.classList.toggle("is-active", value)
    }

    const initial = readWrapLinesPref()
    applyWrapLines(initial)
    this.sync(initial)

    this.onClick = () => {
      const next = this.el.getAttribute("aria-pressed") !== "true"
      writeWrapLinesPref(next)
      applyWrapLines(next)
      this.sync(next)
    }
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },
}

export default WrapLinesToggle
