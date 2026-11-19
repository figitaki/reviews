import assert from "node:assert/strict"
import { test } from "node:test"
import { formatRelative, threadPermalink, tokenBindingText } from "./annotation_ui.js"
import { Comment } from "../schemas.js"

test("the Token row names access-token binding, Bearer, or nothing for older comments", () => {
  assert.deepEqual(tokenBindingText("dpop"), ["Access token bound to agent key", null])
  assert.deepEqual(tokenBindingText("bearer"), ["Bearer", "not bound to a key"])
  assert.equal(tokenBindingText(null), null)
  assert.equal(tokenBindingText(undefined), null)
})

test("comment times are short, rounded down, with the spoken form kept", () => {
  const now = Date.parse("2026-11-19T12:00:00Z")
  const ago = (sec) => formatRelative(new Date(now - sec * 1000).toISOString(), now)
  assert.equal(ago(20).short, "now")
  assert.equal(ago(59).short, "now")
  assert.equal(ago(60).short, "1min")
  assert.equal(ago(56 * 60 + 50).short, "56min")
  assert.equal(ago(3 * 3600 + 59 * 60).short, "3h")
  assert.equal(ago(22 * 3600).short, "22h")
  assert.equal(ago(22 * 3600).relative, "22 hours ago")
  assert.equal(ago(36 * 3600).short, "1d")
  assert.equal(ago(13 * 86400).short, "1w")
  assert.equal(ago(400 * 86400).short, "1y")
  assert.equal(formatRelative("not a date").short, "")
})

test("thread and comment links keep the view and patchset and replace an older target", () => {
  const page = "https://reviews.example/r/abc/changes?patchset=2&section=3&thread=9&comment=4#x"
  assert.equal(threadPermalink(45, undefined, page), "https://reviews.example/r/abc/changes?patchset=2&thread=45")
  assert.equal(threadPermalink(45, 7, page), "https://reviews.example/r/abc/changes?patchset=2&thread=45&comment=7")
})

test("comment authors keep the name and kind that <.ds_identity> shows", () => {
  const author = { id: 1, username: "claude", handle: "claude", display_name: "Claude", kind: "agent", avatar_url: null }
  const comment = Comment.parse({ id: 1, body: "Hi", author, attribution: null, inserted_at: null })
  assert.deepEqual(comment.author, author)
})
