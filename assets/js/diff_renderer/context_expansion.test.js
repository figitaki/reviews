import { expect, test } from "bun:test"
import { loadFileContext } from "./context_expansion.js"

test("shares reads between islands and retries failed context loads", async () => {
  const original = globalThis.fetch
  let requests = 0
  globalThis.fetch = async () => {
    requests++
    return Response.json({ old: "old\n", new: "new\n" })
  }
  try {
    const contexts = await Promise.all([loadFileContext("/context/shared"), loadFileContext("/context/shared")])
    expect(contexts).toEqual([{ old: "old\n", new: "new\n" }, { old: "old\n", new: "new\n" }])
    await loadFileContext("/context/shared")
    expect(requests).toBe(1)
    globalThis.fetch = async () => Response.json({ error: "Unavailable" }, { status: 502 })
    await expect(loadFileContext("/context/retry")).rejects.toThrow("Unavailable")
    globalThis.fetch = async () => Response.json({ old: "a", new: "b" })
    expect(await loadFileContext("/context/retry")).toEqual({ old: "a", new: "b" })
  } finally { globalThis.fetch = original }
})

test("bounds retained files and rejects malformed source", async () => {
  const original = globalThis.fetch
  let requests = 0
  globalThis.fetch = async () => {
    requests++
    return Response.json({ old: "a", new: "b" })
  }
  try {
    for (let i = 0; i < 5; i++) await loadFileContext(`/context/bounded-${i}`)
    await loadFileContext("/context/bounded-0")
    expect(requests).toBe(6)
    globalThis.fetch = async () => Response.json({ old: 123 })
    await expect(loadFileContext("/context/malformed")).rejects.toThrow("Could not read file context.")
  } finally { globalThis.fetch = original }
})
