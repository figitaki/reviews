// Copy-to-clipboard for the .l-install snippet. Pure DOM — no LiveView round-trip
// is needed for clipboard.

const FEEDBACK_MS = 1400

const InstallCopy = {
  mounted() {
    const root = this.el
    const button = root.querySelector("[data-install-copy]")
    const cmdEl = root.querySelector("[data-install-cmd]")
    if (!button || !cmdEl) return

    const command = root.dataset.installCommand || cmdEl.textContent.trim()

    this._onClick = async () => {
      try {
        await navigator.clipboard.writeText(command)
      } catch (e) {
        // Older browsers without async clipboard — try the legacy path quietly.
        const ta = document.createElement("textarea")
        ta.value = command
        ta.setAttribute("readonly", "")
        ta.style.position = "absolute"
        ta.style.left = "-9999px"
        document.body.appendChild(ta)
        ta.select()
        try { document.execCommand("copy") } catch (_) {}
        document.body.removeChild(ta)
      }

      const original = button.textContent
      button.textContent = "Copied"
      button.classList.add("is-copied")
      if (this._timer) window.clearTimeout(this._timer)
      this._timer = window.setTimeout(() => {
        button.textContent = original
        button.classList.remove("is-copied")
      }, FEEDBACK_MS)
    }

    this._button = button
    button.addEventListener("click", this._onClick)
  },

  destroyed() {
    if (this._timer) window.clearTimeout(this._timer)
    if (this._button && this._onClick) this._button.removeEventListener("click", this._onClick)
  },
}

export default InstallCopy
