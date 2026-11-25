import assert from "node:assert/strict"
import { test } from "node:test"
import { resolveDiffStyle } from "./pending_style.js"

test("a clicked style shows before the server's reply", () => {
  // The dataset still says split: the reply has not arrived yet.
  assert.deepEqual(resolveDiffStyle("split", "unified"), { style: "unified", pending: "unified" })
})

test("the reply that agrees clears the pending style", () => {
  assert.deepEqual(resolveDiffStyle("unified", "unified"), { style: "unified", pending: null })
})

test("with nothing pending the dataset decides", () => {
  assert.deepEqual(resolveDiffStyle("split", null), { style: "split", pending: null })
})
