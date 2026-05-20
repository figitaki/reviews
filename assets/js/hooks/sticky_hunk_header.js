const StickyHunkHeader = {
  mounted() {
    this.ticking = false
    this.onScroll = () => {
      if (this.ticking) return
      this.ticking = true
      window.requestAnimationFrame(() => {
        this.updateStuckState()
        this.ticking = false
      })
    }

    this.updateStuckState()
    window.addEventListener("scroll", this.onScroll, {passive: true})
    window.addEventListener("resize", this.onScroll)
  },

  updated() {
    this.updateStuckState()
  },

  destroyed() {
    window.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("resize", this.onScroll)
  },

  updateStuckState() {
    const top = Number.parseFloat(window.getComputedStyle(this.el).top || "0")
    const rect = this.el.getBoundingClientRect()
    const stuck = rect.top <= top + 1
    this.el.classList.toggle("is-stuck", stuck)
    this.el.closest(".review-hunk-card")?.classList.toggle("is-stuck", stuck)
  },
}

export default StickyHunkHeader
