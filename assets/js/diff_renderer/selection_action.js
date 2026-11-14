import { el } from "./dom.js"

// Keep text selection native. Only the explicit row-end action opens a composer.
export class SelectionAction {
  constructor(container, onOpen) {
    this.container = container
    this.onOpen = onOpen
    this.onPointerUp = event => {
      const row = event.composedPath().find(node => node?.hasAttribute?.("data-line"))
      if (row && row === this.lastProps?.lineElement) this.offer(this.lastProps, true)
    }
    container.addEventListener("pointerup", this.onPointerUp)
  }

  offer(props, selected = false) {
    const { lineNumber, lineElement } = props
    const side = props.annotationSide || props.side
    this.lastProps = props
    if (!side || !lineNumber || !lineElement || (this.pinned && !selected)) return
    const lineText = lineElement.textContent || ""
    let anchor = { kind: "line", side, lineNumber, lineText }
    const selection = lineElement.getRootNode().getSelection?.() || document.getSelection()
    if (selected && selection?.rangeCount && !selection.isCollapsed) {
      const range = selection.getRangeAt(0)
      if (lineElement.contains(range.startContainer) && lineElement.contains(range.endContainer)) {
        const before = range.cloneRange()
        before.selectNodeContents(lineElement)
        before.setEnd(range.startContainer, range.startOffset)
        const tokenText = range.toString()
        if (tokenText.trim()) anchor = {
          ...anchor, kind: "token", tokenText,
          lineCharStart: before.toString().length,
          lineCharEnd: before.toString().length + tokenText.length,
        }
      }
    }
    this.anchor = anchor
    this.pinned = selected
    if (!this.button) {
      const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg")
      icon.setAttribute("viewBox", "0 0 24 24")
      icon.setAttribute("aria-hidden", "true")
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
      path.setAttribute("d", "M8 10h8M8 14h5M21 12a9 9 0 0 1-9 9H3l1.5-4A9 9 0 1 1 21 12Z")
      icon.append(path)
      this.button = el("button", {
        type: "button", className: "reviews-row-comment-action",
        onpointerdown: (event) => event.preventDefault(),
        onclick: () => this.onOpen(this.anchor),
        onkeydown: (event) => {
          if (event.key === "Escape") this.clear()
        },
      }, [icon])
      this.container.append(this.button)
    }
    this.button.setAttribute("aria-label", `Comment on ${anchor.kind === "token" ? "selected text" : `line ${lineNumber}`}`)
    this.button.title = this.button.getAttribute("aria-label")
    const row = lineElement.getBoundingClientRect()
    const container = this.container.getBoundingClientRect()
    this.button.style.top = `${row.top - container.top}px`
    this.button.style.right = `${Math.max(4, container.right - row.right + 4)}px`
  }

  destroy() {
    this.clear()
    this.container.removeEventListener("pointerup", this.onPointerUp)
  }

  clear() {
    this.button?.remove()
    this.button = null
    this.anchor = null
    this.pinned = false
  }
}
