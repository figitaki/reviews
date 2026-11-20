const files = new Map()
const MAX_CACHED_FILES = 4

export function loadFileContext(url) {
  if (files.has(url)) return files.get(url)
  const pending = fetch(url, { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(20000) })
    .then(async response => {
      const body = await response.json()
      if (!response.ok) throw new Error(body.error || "Could not load context. Try again.")
      if (typeof body.old !== "string" || typeof body.new !== "string") {
        throw new Error("Could not read file context.")
      }
      return body
    })
    .catch(error => { if (files.get(url) === pending) files.delete(url); throw error })
  files.set(url, pending)
  if (files.size > MAX_CACHED_FILES) files.delete(files.keys().next().value)
  return pending
}
