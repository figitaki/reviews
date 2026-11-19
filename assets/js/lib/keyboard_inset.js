// The on-screen keyboard shrinks the visual viewport but not the layout one
// on iOS Safari. Report how much of the layout viewport it covers.
export function keyboardInset(layoutHeight, viewport) {
  if (!viewport) return 0
  return Math.max(0, Math.round(layoutHeight - viewport.height - viewport.offsetTop))
}

// Smaller changes are browser bars sliding in and out, not a keyboard.
export const KEYBOARD_MIN = 120

// Marks <html> while the keyboard is up (CSS hides the floating controls) and
// keeps the focused comment box and its buttons above the keyboard.
export function watchKeyboard(win = window) {
  const viewport = win.visualViewport
  if (!viewport) return
  const root = win.document.documentElement
  const update = () => {
    const inset = keyboardInset(win.innerHeight, viewport)
    const open = inset >= KEYBOARD_MIN
    root.classList.toggle("is-keyboard-open", open)
    root.style.setProperty("--keyboard-inset", `${open ? inset : 0}px`)
    const field = win.document.activeElement
    if (!open || field?.tagName !== "TEXTAREA") return
    const box = field.closest("[role=group]") || field
    const bottom = box.getBoundingClientRect().bottom
    const visibleBottom = viewport.offsetTop + viewport.height - 8
    if (bottom > visibleBottom) win.scrollBy({ top: bottom - visibleBottom, behavior: "instant" })
  }
  viewport.addEventListener("resize", update)
  viewport.addEventListener("scroll", update)
  win.document.addEventListener("focusin", () => win.requestAnimationFrame(update))
}
