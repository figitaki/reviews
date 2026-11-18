import { COMPACT } from "../lib/breakpoints.js"

const STORAGE_KEY = "reviews:guide-map-open"

function storage() {
  try { return window.localStorage } catch { return null }
}

// The guide map. Wide screens show it as a sidebar and remember whether the
// reader closed it. Compact screens show it as an overlay, so it starts closed
// on every page and closes whenever the reader moves to another page,
// including LiveView patches to another review and back/forward.
export const GuideFlyout = {
  mounted() {
    this.compact = () => window.matchMedia(COMPACT).matches
    const saved = this.compact() ? null : storage()?.getItem(STORAGE_KEY)
    this.open = saved == null ? !this.compact() : saved === "true"
    this.path = window.location.pathname
    this.toggle = this.el.querySelector("[data-guide-flyout-toggle]")
    this.panel = this.el.querySelector("[data-guide-flyout-panel]")
    this.ticks = this.el.querySelector(".review-edge-rail-ticks")

    // Reveal the rail before restoring focus to its menu button.
    this.setOpen = (open, { focusToggle = false } = {}) => {
      if (open === this.open) return
      this.open = open
      if (!this.compact()) storage()?.setItem(STORAGE_KEY, String(open))
      this.sync()
      if (!open && focusToggle) this.toggle?.focus({ preventScroll: true })
    }

    this.onToggle = event => {
      event.preventDefault()
      this.setOpen(!this.open)
      if (!this.open) return
      // Inert is lifted in this same task; focus after the next frame so
      // the browser sees the panel as focusable again.
      window.requestAnimationFrame(() => {
        if (!this.open) return
        const first =
          this.panel?.querySelector(".review-guide-flyout-section") ||
          this.panel?.querySelector("[data-guide-flyout-close]")
        first?.focus({ preventScroll: true })
      })
    }

    this.onKeyDown = event => {
      if (event.key !== "Escape" || !this.open) return
      this.setOpen(false, { focusToggle: true })
    }

    this.onPanelClick = event => {
      if (event.target.closest("[data-guide-flyout-close]")) {
        this.setOpen(false, { focusToggle: true })
      }
    }

    // A patch keeps this hook mounted, so a new page has to close the
    // overlay itself. Query changes on the same page (?thread=…) do not.
    this.onNavigate = () => {
      if (window.location.pathname === this.path) return
      this.path = window.location.pathname
      if (this.compact()) this.setOpen(false)
    }

    this.toggle?.addEventListener("click", this.onToggle)
    this.panel?.addEventListener("click", this.onPanelClick)
    window.addEventListener("keydown", this.onKeyDown)
    window.addEventListener("phx:page-loading-stop", this.onNavigate)
    window.addEventListener("popstate", this.onNavigate)
    this.sync()
  },

  updated() {
    // LiveView patches reset the server-rendered attributes; reapply.
    this.onNavigate()
    this.sync()
  },

  destroyed() {
    this.toggle?.removeEventListener("click", this.onToggle)
    this.panel?.removeEventListener("click", this.onPanelClick)
    window.removeEventListener("keydown", this.onKeyDown)
    window.removeEventListener("phx:page-loading-stop", this.onNavigate)
    window.removeEventListener("popstate", this.onNavigate)
    // The phone Sections button lives outside this element and outlasts it.
    document.querySelector("[data-quick-sections]")?.setAttribute("aria-expanded", "false")
  },

  sync() {
    const open = this.open
    this.el.classList.toggle("is-flyout-open", open)
    if (this.panel) this.panel.inert = !open
    if (this.ticks) this.ticks.inert = open
    this.toggle?.setAttribute("aria-expanded", open ? "true" : "false")
    this.toggle?.setAttribute("aria-label", open ? "Close guide map" : "Open guide map")
    // The phone Sections button toggles this map too.
    document.querySelector("[data-quick-sections]")
      ?.setAttribute("aria-expanded", open ? "true" : "false")
  },
}

export default GuideFlyout
