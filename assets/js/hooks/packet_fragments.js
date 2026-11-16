// Fragments never reach the HTTP server. Resolve them after LiveView connects,
// and wait for its reply (and DOM patch) before focusing the revealed card.
export default {
  mounted() {
    this.patchset = this.el.dataset.patchset
    this.sequence = 0
    this.onHash = () => {
      const previous = this.fragmentId
      this.revealFragment()
      if (!window.location.hash && previous) {
        this.pushEvent("select_packet_overview", {})
      }
    }
    this.onClick = event => {
      if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
      const link = event.target.closest?.("a[href]")
      if (!link || link.hasAttribute("download") || (link.target && link.target !== "_self")) return
      const url = new URL(link.href, window.location.href)
      if (url.origin !== window.location.origin || url.pathname !== window.location.pathname || url.search !== window.location.search) return
      // A repeated fragment does not emit hashchange. Native navigation handles
      // history for changed fragments; explicitly reveal only repeated ones.
      if (url.hash && url.hash === window.location.hash) this.revealFragment()
    }
    window.addEventListener("hashchange", this.onHash)
    this.el.addEventListener("click", this.onClick)
    this.revealFragment()
  },

  updated() {
    if (this.patchset !== this.el.dataset.patchset) {
      this.patchset = this.el.dataset.patchset
      this.revealFragment()
    }
  },

  reconnected() { this.revealFragment() },

  revealFragment() {
    const sequence = ++this.sequence
    const hash = window.location.hash
    this.fragmentId = null
    let id
    try { id = decodeURIComponent(hash.slice(1)) } catch { return }
    if (!id.startsWith("packet-section-")) return
    this.fragmentId = id
    this.pushEvent("reveal_packet_fragment", {id}, reply => {
      if (!reply.id || sequence !== this.sequence || hash !== window.location.hash) return
      window.dispatchEvent(new CustomEvent("phx:packet_nav_jump", {detail: {id: reply.id}}))
    })
  },

  destroyed() {
    ++this.sequence
    window.removeEventListener("hashchange", this.onHash)
    this.el.removeEventListener("click", this.onClick)
  },
}
