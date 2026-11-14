// Line wrapping for diffs (#54).
//
// Prose files (Markdown and friends) usually hold one paragraph per line, so
// they always wrap. Code keeps horizontal scrolling unless the reader turns on
// "Wrap lines", which is a per-browser preference stored in localStorage and
// mirrored on <html data-wrap-lines> so every DiffRenderer can observe it.

export const WRAP_LINES_KEY = "reviews:wrapLines"
export const WRAP_LINES_ATTR = "data-wrap-lines"

const PROSE_EXTENSIONS = new Set([
  "md",
  "mdx",
  "markdown",
  "txt",
  "text",
  "rst",
  "adoc",
  "asciidoc",
  "org",
])

export function isProseFile(filePath) {
  if (typeof filePath !== "string") return false
  const name = filePath.split("/").pop() || ""
  const dot = name.lastIndexOf(".")
  if (dot <= 0) return false
  return PROSE_EXTENSIONS.has(name.slice(dot + 1).toLowerCase())
}

// Pierre's `overflow` option: "wrap" keeps gutter rows aligned with wrapped
// content in both split and unified layouts.
export function diffOverflow({ filePath, wrapLines }) {
  return wrapLines || isProseFile(filePath) ? "wrap" : "scroll"
}

export function readWrapLinesPref(storage = safeLocalStorage()) {
  try {
    return storage?.getItem(WRAP_LINES_KEY) === "true"
  } catch {
    return false
  }
}

export function writeWrapLinesPref(value, storage = safeLocalStorage()) {
  try {
    storage?.setItem(WRAP_LINES_KEY, value ? "true" : "false")
  } catch {
    // Private mode or blocked storage: the toggle still works for this page.
  }
}

export function wrapLinesEnabled(root = globalThis.document?.documentElement) {
  return root?.getAttribute?.(WRAP_LINES_ATTR) === "true"
}

export function applyWrapLines(value, root = globalThis.document?.documentElement) {
  root?.setAttribute?.(WRAP_LINES_ATTR, value ? "true" : "false")
}

function safeLocalStorage() {
  try {
    return globalThis.localStorage
  } catch {
    return null
  }
}
