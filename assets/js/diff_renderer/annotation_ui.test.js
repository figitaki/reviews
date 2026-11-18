import assert from "node:assert/strict"
import { test } from "node:test"
import { tokenBindingText } from "./annotation_ui.js"

test("the Token row names RFC 9449 access-token binding, Bearer, or nothing for older comments", () => {
  assert.deepEqual(tokenBindingText("dpop"), ["Access token bound to agent key (DPoP, RFC 9449)", null])
  assert.deepEqual(tokenBindingText("bearer"), ["Bearer", "not bound to a key"])
  assert.equal(tokenBindingText(null), null)
  assert.equal(tokenBindingText(undefined), null)
})
