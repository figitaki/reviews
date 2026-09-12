const key = "reviews-demo-qa-v1"
export default {
  mounted() {
    this.root = this.el.closest("#demo-checklist")
    this.restore = () => {
      let saved = []
      try { saved = JSON.parse(localStorage.getItem(key) || "[]") } catch {}
      for (const input of this.root.querySelectorAll("[data-demo-check]")) {
        input.checked = Array.isArray(saved) && saved.includes(input.id)
      }
      this.progress()
    }
    this.progress = () => {
      const all = [...this.root.querySelectorAll("[data-demo-check]")]
      this.root.querySelector("#demo-progress").textContent = `${all.filter(input => input.checked).length} of ${all.length} checks complete`
    }
    this.onChange = () => {
      const checked = [...this.root.querySelectorAll("[data-demo-check]:checked")].map(input => input.id)
      try { localStorage.setItem(key, JSON.stringify(checked)) } catch {}
      this.progress()
    }
    this.onReset = () => {
      for (const input of this.root.querySelectorAll("[data-demo-check]")) input.checked = false
      this.onChange()
    }
    this.root.addEventListener("change", this.onChange)
    this.root.querySelector("#demo-reset-checks").addEventListener("click", this.onReset)
    this.restore()
  },
  updated() { this.restore() },
  destroyed() {
    this.root.removeEventListener("change", this.onChange)
    this.root.querySelector("#demo-reset-checks")?.removeEventListener("click", this.onReset)
  },
}
