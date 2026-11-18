import assert from "node:assert/strict"
import { test } from "node:test"
import { tokenBindingText } from "./annotation_ui.js"

test("the Token row names access-token binding, Bearer, or nothing for older comments", () => {
  assert.deepEqual(tokenBindingText("dpop"), ["Access token bound to agent key", null])
  assert.deepEqual(tokenBindingText("bearer"), ["Bearer", "not bound to a key"])
  assert.equal(tokenBindingText(null), null)
  assert.equal(tokenBindingText(undefined), null)
})
