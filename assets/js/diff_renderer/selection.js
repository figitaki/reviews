// A click that ends a text selection (drag, double-click, triple-click) must
// not open the comment composer: opening it re-renders the diff and throws
// the selection away, so the reader can't copy code (#56).
export function selectionInProgress(event, node, doc = globalThis.document) {
  if (event && event.detail > 1) return true

  const root = node?.getRootNode?.()
  const selections = [root?.getSelection?.(), doc?.getSelection?.()]
  return selections.some(
    (selection) =>
      selection && !selection.isCollapsed && selection.toString().length > 0
  )
}
