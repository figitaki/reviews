import { el } from "./dom.js"

// One non-modal conversation floats above the review. It lives outside Pierre's
// shadow DOM so diff overflow/virtualization cannot clip it. Closing is not resolving.
let activeConversation = null

export class MobileConversation {
  show(content, title, onClose, opener) {
    if (activeConversation && activeConversation !== this) activeConversation.close(false)
    activeConversation = this
    const wasOpen = Boolean(this.node)
    const focused = this.node?.contains(document.activeElement) ? document.activeElement : null
    const editing = focused?.tagName === "TEXTAREA"
    const selection = editing ? [focused.selectionStart, focused.selectionEnd] : null
    this.onClose = onClose
    this.opener = opener || this.opener
    if (!this.node) {
      this.node = el("section", {
        role: "dialog", "aria-label": `Conversation in ${title}`,
        dataset: { mobileConversation: "true" },
        style: {
          position: "fixed", left: "12px", right: "12px", zIndex: "60",
          background: "var(--ds-panel)", color: "var(--ds-text)",
          border: "1px solid var(--ds-line-strong)", borderRadius: "12px",
          overflow: "auto", overscrollBehavior: "contain", padding: "0",
          fontFamily: "var(--font-sans, system-ui, sans-serif)", fontSize: "13px",
        },
      })
      this.resize = () => {
        const viewport = window.visualViewport
        const height = viewport?.height || window.innerHeight
        const offset = Math.max(0, window.innerHeight - height - (viewport?.offsetTop || 0))
        this.node.style.bottom = `calc(${offset + 12}px + env(safe-area-inset-bottom, 0px))`
        this.node.style.maxHeight = `calc(${height - 24}px - env(safe-area-inset-bottom, 0px))`
        window.requestAnimationFrame(() => {
          const textarea = document.activeElement
          if (!this.node?.contains(textarea) || textarea.tagName !== "TEXTAREA") return
          const editor = textarea.closest('[aria-label="Comment composer"]')
          const overflow = editor.getBoundingClientRect().bottom - this.node.getBoundingClientRect().bottom + 12
          if (overflow > 0) this.node.scrollTop += overflow
        })
      }
      this.escape = (event) => {
        if (event.key === "Escape" && !event.defaultPrevented) {
          event.preventDefault()
          this.close()
        }
      }
      this.node.addEventListener("keydown", this.escape)
      this.node.addEventListener("focusin", this.resize)
      window.visualViewport?.addEventListener("resize", this.resize)
      window.visualViewport?.addEventListener("scroll", this.resize)
      window.addEventListener("resize", this.resize)
      document.body.append(this.node)
    }
    const close = el("button", {
      type: "button", "aria-label": "Close conversation",
      onclick: () => this.close(),
      style: { color: "inherit", background: "transparent", border: "none", minWidth: "44px", minHeight: "44px", fontSize: "20px", cursor: "pointer" },
    }, "×")
    this.node.replaceChildren(el("header", {
      style: { position: "sticky", top: "0", zIndex: "1", background: "var(--ds-panel)", display: "flex", alignItems: "center", justifyContent: "space-between", gap: "12px", paddingLeft: "12px", borderBottom: "1px solid var(--ds-line)" },
    }, [el("span", { style: { overflowWrap: "anywhere", minWidth: "0" } }, title), close]), content)
    this.resize()
    if (editing) {
      const textarea = this.node.querySelector("textarea")
      textarea?.focus({ preventScroll: true })
      if (textarea) textarea.setSelectionRange(...selection)
    } else if (!wasOpen || focused) {
      close.focus({ preventScroll: true })
    }
  }

  close(restoreFocus = true) {
    if (!this.node) return
    this.node.remove()
    this.node = null
    window.visualViewport?.removeEventListener("resize", this.resize)
    window.visualViewport?.removeEventListener("scroll", this.resize)
    window.removeEventListener("resize", this.resize)
    if (activeConversation === this) activeConversation = null
    const opener = this.opener?.()
    if (restoreFocus && opener?.isConnected) opener.focus({ preventScroll: true })
    this.onClose?.()
  }
}
