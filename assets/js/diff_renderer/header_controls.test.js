import assert from "node:assert/strict"
import { test } from "node:test"
import { headerToggleLabel, stopHeaderEvent } from "./header_controls.js"

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
