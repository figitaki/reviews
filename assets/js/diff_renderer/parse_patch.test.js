import {test, expect} from "bun:test"
import {parsePatch} from "./vanilla_renderer.js"

const patch = (name, value) => `diff --git a/${name} b/${name}\n--- a/${name}\n+++ b/${name}\n@@ -1 +1 @@\n-old\n+${value}\n`

test("selects the requested file and supplies the parser cache prefix", () => {
  const result = parsePatch(patch("a.js", "first") + patch("b.js", "second"), "b.js")
  expect(result.name).toBe("b.js")
  expect(result.additionLines.join("")).toContain("second")
  expect(result.cacheKey).toContain("b.js")
})

test("keeps old and new line coordinates for annotations", () => {
  const result = parsePatch(patch("a.js", "new"), "a.js")
  expect(result.hunks[0].additionStart).toBe(1)
  expect(result.hunks[0].deletionStart).toBe(1)
  expect(result.additionLines.join("")).toContain("new")
  expect(result.deletionLines.join("")).toContain("old")
})

test("empty patches retain the renderer fallback", () => {
  expect(parsePatch("", "a.js")).toBeNull()
})
