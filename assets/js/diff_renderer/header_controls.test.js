import assert from "node:assert/strict"
import { test } from "node:test"
import { headerToggleLabel, stopHeaderEvent } from "./header_controls.js"
import { VanillaDiffRenderer } from "./vanilla_renderer.js"

test("disclosure names distinguish files and hunks in either state", () => {
  assert.equal(headerToggleLabel("lib/a.ex", { hunkExpanded: true, hunkLabel: "hunk 2" }),
    "Collapse lib/a.ex · hunk 2")
  assert.equal(headerToggleLabel("lib/b.ex", { hunkExpanded: false, hunkLabel: "" }),
    "Expand lib/b.ex")
})

test("header controls consume the click before running their action", () => {
  const event = new Event("click", { bubbles: true, cancelable: true })
  let calls = 0
  stopHeaderEvent(event, () => {
    assert.equal(event.defaultPrevented, true)
    assert.equal(event.cancelBubble, true)
    calls += 1
  })
  assert.equal(calls, 1)
})

test("Markdown mode defaults to Source for discussions and remembers choices per review and file", () => {
  const original = globalThis.window
  const saved = new Map()
  globalThis.window = {
    location: { pathname: "/r/one" },
    localStorage: { getItem: key => saved.get(key) },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
  }
  const container = { addEventListener() {} }
  const mount = (threads = [], filePath = "a.md") => new VanillaDiffRenderer({
    container, filePath, threads, rawDiff: `diff --git a/${filePath} b/${filePath}\n--- a/${filePath}\n+++ b/${filePath}\n@@ -1 +1 @@\n-old\n+new\n`,
  })
  try {
    assert.equal(mount().preview, true)
    assert.equal(mount([{}]).preview, false)
    saved.set("reviews:markdown-view:/r/one:a.md", "preview")
    assert.equal(mount([{}]).preview, true)
    globalThis.window.location.pathname = "/r/one/changes"
    assert.equal(mount([{}]).preview, true)
    assert.equal(mount([{}], "b.md").preview, false)
    saved.set("reviews:markdown-view:/r/one:a.md", "source")
    assert.equal(mount().preview, false)
    globalThis.window.location.pathname = "/r/two"
    assert.equal(mount([{}]).preview, false)
    globalThis.window.localStorage.getItem = () => { throw new Error("Storage disabled") }
    assert.equal(mount().preview, true)
  } finally {
    globalThis.window = original
  }
})
