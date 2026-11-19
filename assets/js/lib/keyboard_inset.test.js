import assert from "node:assert/strict"
import { test } from "node:test"
import { keyboardInset } from "./keyboard_inset.js"

test("the keyboard inset is the layout height the visual viewport no longer covers", () => {
  // iPhone 13 Safari: 664px layout, keyboard leaves 328px visible.
  assert.equal(keyboardInset(664, { height: 328, offsetTop: 0 }), 336)
  // Safari scrolls the visual viewport down while typing; that is not more keyboard.
  assert.equal(keyboardInset(664, { height: 328, offsetTop: 120 }), 216)
  // A visual viewport taller than the layout one never gives a negative inset.
  assert.equal(keyboardInset(664, { height: 700, offsetTop: 0 }), 0)
  assert.equal(keyboardInset(664, null), 0)
})
