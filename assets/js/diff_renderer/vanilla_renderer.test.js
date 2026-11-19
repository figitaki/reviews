import { afterAll, beforeAll, expect, mock, test } from "bun:test"

// Pierre needs a real DOM, so stand-ins record what the renderer asks of it.
// The virtualized stand-in renders only rows near the viewport: thread
// bubbles outside that window exist but have no boxes until it scrolls there.
const calls = { fileDiff: 0, virtualized: 0, scrolls: [] }

class FakeVirtualizer {
  setup() {}
  getOffsetInScrollContainer() { return 500 }
  scrollTo(options) { calls.scrolls.push(options) }
  cleanUp() {}
}

class FakeVirtualizedFileDiff {
  constructor(options) {
    this.options = options
    calls.virtualized += 1
  }
  render() { this.options.onPostRender?.(null, this, "mount") }
  setOptions(options) { this.options = options }
  rerender() { this.options.onPostRender?.(null, this, "update") }
  getLinePosition(lineNumber, side) { return side === "additions" ? { top: lineNumber * 20, height: 20 } : undefined }
  cleanUp() {}
}

class FakeFileDiff extends FakeVirtualizedFileDiff {
  constructor(options) {
    super(options)
    calls.virtualized -= 1
    calls.fileDiff += 1
  }
}

const real = await import("@pierre/diffs")
mock.module("@pierre/diffs", () => ({
  ...real,
  Virtualizer: FakeVirtualizer,
  VirtualizedFileDiff: FakeVirtualizedFileDiff,
  FileDiff: FakeFileDiff,
}))
const { VanillaDiffRenderer } = await import("./vanilla_renderer.js")
const { default: DiffRendererHook } = await import("../hooks/diff_renderer.js")

function fakeElement(extra = {}) {
  return {
    style: {},
    dataset: {},
    className: "",
    offsetHeight: 0,
    append() {},
    replaceChildren() {},
    setAttribute() {},
    addEventListener() {},
    removeEventListener() {},
    contains: () => false,
    querySelector: () => null,
    ...extra,
  }
}

const saved = {}
beforeAll(() => {
  for (const key of ["window", "document", "requestAnimationFrame", "MutationObserver"]) saved[key] = globalThis[key]
  globalThis.MutationObserver = class { observe() {} disconnect() {} }
  const media = { matches: false, addEventListener() {}, removeEventListener() {} }
  globalThis.window = { matchMedia: () => media, innerHeight: 900, location: { pathname: "/r/x" } }
  globalThis.document = {
    activeElement: null,
    documentElement: { dataset: {} },
    createElement: () => fakeElement(),
  }
  globalThis.requestAnimationFrame = (fn) => fn()
})
afterAll(() => Object.assign(globalThis, saved))

// A 4,000-line added file, over the renderer's virtualization threshold.
const lines = Array.from({ length: 4000 }, (_, i) => `+line ${i + 1}`)
const rawDiff = `diff --git a/big.js b/big.js\nnew file mode 100644\n--- /dev/null\n+++ b/big.js\n@@ -0,0 +1,4000 @@\n${lines.join("\n")}\n`

const author = { id: 1, username: "a" }
const thread = (id, line) => ({
  id, file_path: "big.js", side: "new", status: "open", can_update_status: false, author,
  anchor: { granularity: "line", line_number_hint: line, line_text: `line ${line}`, context_before: [], context_after: [] },
  comments: [{ id, body: "hi", author, attribution: null, inserted_at: "2026-11-19T00:00:00Z" }],
})

test("opening a thread keeps a large file virtualized and focuses the thread after scrolling to its line", () => {
  const bubble = { rects: [], focused: false, style: {} }
  Object.assign(bubble, {
    getClientRects: () => bubble.rects,
    scrollIntoView() {},
    focus() { bubble.focused = true },
  })
  const container = fakeElement({
    querySelector: (selector) => (selector === '[data-thread-id="7"]' ? bubble : null),
  })
  const renderer = new VanillaDiffRenderer({
    container, filePath: "big.js", rawDiff, signedIn: true,
    threads: [thread(7, 3000)], diffStyle: "split", hunkUI: null,
  })
  renderer.render()
  expect(container.dataset.virtualized).toBe("true")

  renderer.openThread(7)
  expect(container.dataset.virtualized).toBe("true")
  expect(calls.fileDiff).toBe(0)
  // Line 3000 sits 60,000px into the file, which starts 500px down the page.
  expect(calls.scrolls).toEqual([{ top: 500 + 60000 - 900 / 3, behavior: "instant" }])
  expect(bubble.focused).toBe(false)

  // The virtualizer renders the scrolled-to window; the thread is now laid out.
  bubble.rects = [{}]
  renderer.instance.options.onPostRender(null, renderer.instance, "update")
  expect(bubble.focused).toBe(true)

  // Later updates to the file stay virtualized and do not scroll again.
  renderer.update({ threads: [thread(7, 3000), thread(8, 10)] })
  expect(container.dataset.virtualized).toBe("true")
  expect(calls.fileDiff).toBe(0)
  expect(calls.scrolls).toHaveLength(1)
})

test("collapsing a file shows at once, survives the server's patches, and reuses the highlighted render", async () => {
  calls.fileDiff = 0
  calls.virtualized = 0
  const dataset = {
    filePath: "big.js", rawDiff, threads: "[]", signedIn: "true", diffStyle: "split",
    hunkId: "file-diff-1", hunkExpanded: "true", hunkViewed: "false", hunkPartiallyViewed: "false",
  }
  const replies = []
  const pushed = []
  const hook = Object.create(DiffRendererHook)
  Object.assign(hook, {
    el: fakeElement({ dataset }),
    handleEvent() {},
    pushEvent(event, payload) {
      pushed.push([event, payload])
      return new Promise((resolve) => replies.push(resolve))
    },
  })
  hook.mounted()
  const pierre = hook._renderer.instance
  expect(calls.virtualized).toBe(1)
  expect(pierre.options.collapsed).toBe(false)

  // The chevron collapses the file before the server answers.
  hook._renderer.onToggleHunk()
  expect(pushed).toEqual([["toggle_hunk_diff", { hunk_id: "file-diff-1" }]])
  expect(pierre.options.collapsed).toBe(true)

  // A patch that does not carry the change yet must not reopen the file.
  hook.updated()
  expect(pierre.options.collapsed).toBe(true)

  // The server's reply patches the same state and settles the event.
  dataset.hunkExpanded = "false"
  hook.updated()
  replies.shift()()
  await Promise.resolve()
  expect(pierre.options.collapsed).toBe(true)

  // Expanding again shows at once and keeps the same Pierre instance, so the
  // file is not highlighted again.
  hook._renderer.onToggleHunk()
  expect(pierre.options.collapsed).toBe(false)
  dataset.hunkExpanded = "true"
  hook.updated()
  replies.shift()()
  await Promise.resolve()
  expect(hook._renderer.instance).toBe(pierre)
  expect(pierre.options.collapsed).toBe(false)
  expect(calls.virtualized).toBe(1)
  expect(calls.fileDiff).toBe(0)
})
