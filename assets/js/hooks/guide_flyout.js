const GuideFlyout = {
  mounted() {
    this.open = false
    this.toggle = this.el.querySelector("[data-guide-flyout-toggle]")
    this.panel = this.el.querySelector("[data-guide-flyout-panel]")

    this.onToggle = event => {
      event.preventDefault()
      this.open = !this.open
      this.sync()
    }

    this.onKeyDown = event => {
      if (event.key !== "Escape") return
      if (!this.isOpen()) return

      this.open = false
      this.sync()
      this.toggle?.focus()
    }

    this.onPanelClick = event => {
      if (!event.target.closest("[phx-click]")) return

      this.open = false
      this.sync()
    }

    this.toggle?.addEventListener("click", this.onToggle)
    this.panel?.addEventListener("click", this.onPanelClick)
    window.addEventListener("keydown", this.onKeyDown)
    this.sync()
  },

  destroyed() {
    this.toggle?.removeEventListener("click", this.onToggle)
    this.panel?.removeEventListener("click", this.onPanelClick)
    window.removeEventListener("keydown", this.onKeyDown)
  },

  isOpen() {
    return this.open
  },

  sync() {
    const open = this.isOpen()
    this.el.classList.toggle("is-flyout-open", open)
    this.panel?.setAttribute("aria-hidden", open ? "false" : "true")
    this.toggle?.setAttribute("aria-expanded", open ? "true" : "false")
  },
}

export default GuideFlyout
