import assert from "node:assert/strict"
import { test } from "node:test"

import {
  WRAP_LINES_ATTR,
  WRAP_LINES_KEY,
  applyWrapLines,
  diffOverflow,
  isProseFile,
  readWrapLinesPref,
  wrapLinesEnabled,
  writeWrapLinesPref,
} from "./line_wrap.js"

test("prose files are detected by extension", () => {
  for (const path of [
    "README.md",
    "docs/guide.MDX",
    "notes.markdown",
    "LICENSE.txt",
    "docs/index.rst",
    "book/chapter.adoc",
  ]) {
    assert.equal(isProseFile(path), true, path)
  }
})

test("code and extensionless files are not prose", () => {
  for (const path of ["lib/a.ex", "assets/js/app.js", "Makefile", ".md", "md/file.ex", null]) {
    assert.equal(isProseFile(path), false, String(path))
  }
})

test("prose wraps by default and code scrolls", () => {
  assert.equal(diffOverflow({ filePath: "README.md", wrapLines: false }), "wrap")
  assert.equal(diffOverflow({ filePath: "lib/a.ex", wrapLines: false }), "scroll")
})

test("the wrap toggle wraps code too", () => {
  assert.equal(diffOverflow({ filePath: "lib/a.ex", wrapLines: true }), "wrap")
  assert.equal(diffOverflow({ filePath: "README.md", wrapLines: true }), "wrap")
})

test("the preference round-trips through storage", () => {
  const data = new Map()
  const storage = { getItem: (k) => data.get(k) ?? null, setItem: (k, v) => data.set(k, v) }
  assert.equal(readWrapLinesPref(storage), false)
  writeWrapLinesPref(true, storage)
  assert.equal(data.get(WRAP_LINES_KEY), "true")
  assert.equal(readWrapLinesPref(storage), true)
})

test("storage errors fall back to no wrapping", () => {
  const storage = {
    getItem: () => {
      throw new Error("blocked")
    },
    setItem: () => {
      throw new Error("blocked")
    },
  }
  assert.equal(readWrapLinesPref(storage), false)
  assert.doesNotThrow(() => writeWrapLinesPref(true, storage))
})

test("the root attribute carries the toggle state", () => {
  const attrs = new Map()
  const root = {
    getAttribute: (k) => attrs.get(k) ?? null,
    setAttribute: (k, v) => attrs.set(k, v),
  }
  assert.equal(wrapLinesEnabled(root), false)
  applyWrapLines(true, root)
  assert.equal(attrs.get(WRAP_LINES_ATTR), "true")
  assert.equal(wrapLinesEnabled(root), true)
})
