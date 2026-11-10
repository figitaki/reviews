export function headerToggleLabel(filePath, hunkUI) {
  const action = hunkUI.hunkExpanded ? "Collapse" : "Expand"
  const hunk = hunkUI.hunkLabel ? ` · ${hunkUI.hunkLabel}` : ""
  return `${action} ${filePath}${hunk}`
}

export function stopHeaderEvent(event, callback) {
  event.preventDefault()
  event.stopPropagation()
  callback?.()
}
