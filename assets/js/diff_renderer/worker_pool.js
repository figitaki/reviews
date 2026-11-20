import { getOrCreateWorkerPoolSingleton } from "@pierre/diffs/worker"

// Both Pierre themes, so switching between light and dark only changes CSS
// and never highlights a file again.
export const PIERRE_THEMES = { dark: "pierre-dark", light: "pierre-light" }

let pool

// Pierre highlights a whole file at once, which on the main thread blocks the
// page for seconds on a large file. With a worker pool it renders plain text
// first and fills in the colours when a worker returns them. The page names
// the worker script in <meta name="diffs-worker">; without it, or without
// Worker, Pierre highlights on the main thread as before.
export function highlightWorkers() {
  if (pool !== undefined) return pool
  pool = null
  const url = document.querySelector?.('meta[name="diffs-worker"]')?.content
  if (!url || typeof Worker === "undefined") return pool
  pool = getOrCreateWorkerPoolSingleton({
    poolOptions: {
      workerFactory: () => new Worker(url),
      poolSize: Math.max(1, Math.min(4, (navigator.hardwareConcurrency || 2) - 1)),
      // Short diffs highlight faster than a worker round trip and show their
      // colours without a plain-text pass.
      mainThreadMaxCharacters: 4000,
    },
    highlighterOptions: { theme: PIERRE_THEMES },
  })
  pool.initialize().catch(() => { /* Pierre falls back to the main thread. */ })
  return pool
}
