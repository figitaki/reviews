const StickyProse = {
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

  destroyed() {
    window.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("resize", this.onScroll)
  },

  updateStuckState() {
    const top = Number.parseFloat(window.getComputedStyle(this.el).top || "0")
    const rect = this.el.getBoundingClientRect()
    this.el.classList.toggle("is-stuck", rect.top <= top + 1)
  },
}

export default StickyProse
