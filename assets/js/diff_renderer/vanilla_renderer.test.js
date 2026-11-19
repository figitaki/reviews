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
  constructor(options, virtualizer, metrics, workers) {
    this.options = options
    this.workers = workers
    calls.virtualized += 1
  }
  render() { this.options.onPostRender?.(null, this, "mount") }
  setOptions(options) { this.options = options }
  setLineAnnotations(annotations) { this.annotations = annotations }
  setSelectedLines(range) { this.selectedLines = range }
  rerender() { this.options.onPostRender?.(null, this, "update") }
  getLinePosition(lineNumber, side) { return side === "additions" ? { top: lineNumber * 20, height: 20 } : undefined }
  cleanUp() {}
}

class FakeFileDiff extends FakeVirtualizedFileDiff {
  constructor(options, workers) {
    super(options, null, null, workers)
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
const workers = { name: "worker pool" }
mock.module("./worker_pool.js", () => ({
  PIERRE_THEMES: { dark: "pierre-dark", light: "pierre-light" },
  highlightWorkers: () => workers,
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
  comments: [{ id, body_html: "<p>hi</p>\n", author, attribution: null, inserted_at: "2026-11-19T00:00:00Z" }],
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

test("large and small files highlight through the worker pool in both themes", () => {
  calls.fileDiff = 0
  const renderer = new VanillaDiffRenderer({
    container: fakeElement(), filePath: "big.js", rawDiff, signedIn: false,
    threads: [], diffStyle: "split", hunkUI: null,
  })
  renderer.render()
  expect(renderer.instance.workers).toBe(workers)
  expect(renderer.instance.options.theme).toEqual({ dark: "pierre-dark", light: "pierre-light" })

  const small = new VanillaDiffRenderer({
    container: fakeElement(), filePath: "a.js", signedIn: false, threads: [], diffStyle: "split", hunkUI: null,
    rawDiff: "diff --git a/a.js b/a.js\n--- a/a.js\n+++ b/a.js\n@@ -1 +1 @@\n-old\n+new\n",
  })
  small.render()
  expect(calls.fileDiff).toBe(1)
  expect(small.instance.workers).toBe(workers)
})

test("closing the composer clears the lines the gutter drag selected", () => {
  const renderer = new VanillaDiffRenderer({
    container: fakeElement(), filePath: "a.js", signedIn: true, threads: [], diffStyle: "unified", hunkUI: null,
    rawDiff: "diff --git a/a.js b/a.js\n--- a/a.js\n+++ b/a.js\n@@ -1 +1,5 @@\n-old\n+a\n+b\n+c\n+d\n+e\n",
  })
  renderer.render()
  const pierre = renderer.instance
  // Pierre selected lines 2 to 5 while the "+" was dragged; the composer opens on 5.
  const dragged = { start: 2, end: 5, side: "additions" }
  pierre.selectedLines = dragged
  renderer.setComposerAt({ side: "additions", lineNumber: 5, kind: "comment" })
  expect(pierre.selectedLines).toBe(dragged)

  // Cancel, Escape and posting all close it through setComposerAt(null).
  renderer.setComposerAt(null)
  expect(pierre.selectedLines).toBeNull()
})

test("updates that keep the diff reuse the Pierre instance", () => {
  for (const [filePath, patch] of [
    ["big.js", rawDiff],
    ["a.js", "diff --git a/a.js b/a.js\n--- a/a.js\n+++ b/a.js\n@@ -1 +1 @@\n-old\n+new\n"],
  ]) {
    calls.fileDiff = 0
    calls.virtualized = 0
    const renderer = new VanillaDiffRenderer({
      container: fakeElement(), filePath, rawDiff: patch, signedIn: true,
      threads: [], diffStyle: "split", hunkUI: null,
    })
    renderer.render()
    const pierre = renderer.instance

    // Style, threads, the composer and open threads each lay the same
    // instance out again instead of building and highlighting the file anew.
    renderer.updateStyle("unified")
    expect(pierre.options.diffStyle).toBe("unified")
    renderer.update({ threads: [{ ...thread(9, 1), file_path: filePath }] })
    expect(pierre.annotations.map((a) => a.lineNumber)).toEqual([1])
    renderer.setComposerAt({ side: "additions", lineNumber: 1, kind: "comment" })
    expect(pierre.annotations.map((a) => a.metadata.kind)).toEqual(["real", "composer"])
    renderer.openThread(9)

    expect(renderer.instance).toBe(pierre)
    expect(calls.virtualized + calls.fileDiff).toBe(1)
  }
})
