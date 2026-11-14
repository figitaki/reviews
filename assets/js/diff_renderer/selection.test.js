import assert from "node:assert/strict"
import { test } from "node:test"

import { selectionInProgress } from "./selection.js"

const selection = (text) => ({ isCollapsed: text.length === 0, toString: () => text })
const docWith = (text) => ({ getSelection: () => selection(text) })
const nodeInShadowWith = (text) => ({
  getRootNode: () => ({ getSelection: () => selection(text) }),
})

test("a plain click with no selection opens the composer", () => {
  assert.equal(selectionInProgress({ detail: 1 }, nodeInShadowWith(""), docWith("")), false)
})

test("a drag that selects text inside the diff shadow root is a selection", () => {
  assert.equal(selectionInProgress({ detail: 1 }, nodeInShadowWith("const a = 1"), docWith("")), true)
})

test("a selection reported only by the document is a selection", () => {
  assert.equal(selectionInProgress({ detail: 1 }, {}, docWith("foo")), true)
})

test("double and triple clicks select words and lines", () => {
  assert.equal(selectionInProgress({ detail: 2 }, null, docWith("")), true)
  assert.equal(selectionInProgress({ detail: 3 }, null, docWith("")), true)
})

test("missing event, node, and document do not throw", () => {
  assert.equal(selectionInProgress(undefined, undefined, undefined), false)
})
