function optionalInteger(value) {
  if (value == null || value === "") return undefined
  const parsed = Number.parseInt(value, 10)
  return Number.isNaN(parsed) ? undefined : parsed
}

export function hunkUIFromDataset(dataset) {
  return {
    hunkId: dataset.hunkId || "",
    label: dataset.hunkLabel || "",
    details: dataset.hunkDetails || "",
    expanded: dataset.hunkExpanded === "true",
    viewed: dataset.hunkViewed === "true",
    partiallyViewed: dataset.hunkPartiallyViewed === "true",
    viewState: dataset.hunkViewState || "",
    signedIn: dataset.signedIn === "true",
    payload: {
      file_path: dataset.filePath,
      row_ref: dataset.rowRef,
      hunk_fingerprint: dataset.hunkFingerprint,
      hunk_id: dataset.hunkId,
      hunk_attrs: dataset.hunkAttrs,
      hunk_index: optionalInteger(dataset.hunkIndex),
      line_start: optionalInteger(dataset.lineStart),
      line_end: optionalInteger(dataset.lineEnd),
      section_index: optionalInteger(dataset.sectionIndex),
      section_title: dataset.sectionTitle,
    },
  }
}

export function compactHunkPayload(payload) {
  return Object.fromEntries(
    Object.entries(payload).filter(([, value]) => value !== undefined && value !== "")
  )
}

export function hunkViewLabel(hunkUI) {
  if (hunkUI.viewed) return "Viewed"
  if (hunkUI.partiallyViewed) return "Partially viewed"
  return hunkUI.viewState
}
