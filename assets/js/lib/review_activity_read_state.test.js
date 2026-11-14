import assert from "node:assert/strict"
import { test } from "node:test"
import { ReviewActivityReadState } from "./review_activity_read_state.js"

function memoryStorage() {
  const values = new Map()
  return {
    getItem: key => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, value),
  }
}

const thread = (...comments) => ({ comments: comments.map(([id, authorId]) => ({ id: String(id), authorId: String(authorId) })) })

test("initialization and updates do not mark comments read; own comments do not count", () => {
  const storage = memoryStorage()
  const state = new ReviewActivityReadState("review", "me", storage)
  const first = thread([1, "other"], [2, "me"])
  assert.equal(state.unread(first, "me"), 1)
  state.refresh()
  assert.equal(state.unread(first, "me"), 1)
  assert.equal(storage.getItem(state.key), null)
  assert.equal(state.unread(first, null), 2)
})

test("explicit read persists comment IDs; later replies and out-of-order IDs stay unread", () => {
  const storage = memoryStorage()
  const state = new ReviewActivityReadState("review", "me", storage)
  state.markRead([thread([10, "other"], [20, "me"])])
  const restored = new ReviewActivityReadState("review", "me", storage)
  assert.equal(restored.unread(thread([10, "other"], [20, "me"]), "me"), 0)
  assert.equal(restored.unread(thread([9, "other"], [10, "other"], [30, "other"], [40, "me"]), "me"), 2)
})

test("clicked-thread reads leave other threads unread; mark all reads exactly the supplied snapshot", () => {
  const state = new ReviewActivityReadState("review", "me", memoryStorage())
  const first = thread([1, "other"])
  const second = thread([2, "other"])
  state.markRead([first])
  assert.equal(state.unread(second, "me"), 1)
  state.markRead([first, second])
  assert.equal(state.unread(second, "me"), 0)
  assert.equal(state.unread(thread([2, "other"], [3, "other"]), "me"), 1)
})

test("read state is isolated by review, identity and anonymous browser viewer", () => {
  const storage = memoryStorage()
  new ReviewActivityReadState("one", "me", storage).markRead([thread([1, "other"])])
  for (const [review, identity] of [["two", "me"], ["one", "you"], ["one", null]]) {
    assert.equal(new ReviewActivityReadState(review, identity, storage).unread(thread([1, "other"]), identity), 1)
  }
})

test("missing, throwing, corrupt and quota-exceeded storage preserve session reads", () => {
  const failing = () => { throw new Error("unavailable") }
  for (const storage of [null, { getItem: failing }, { getItem: () => "{bad" }, { getItem: () => null, setItem: failing }]) {
    const state = new ReviewActivityReadState("review", "me", storage)
    state.markRead([thread([1, "other"])])
    state.refresh()
    assert.equal(state.persistent, false)
    assert.equal(state.unread(thread([1, "other"], [2, "other"]), "me"), 1)
  }
})

test("invalid storage values cannot acknowledge comments", () => {
  for (const raw of ["{}", "null", '[1]', '["1",null]']) {
    const storage = { getItem: () => raw, setItem: () => {} }
    const state = new ReviewActivityReadState("review", "me", storage)
    assert.equal(state.unread(thread([1, "other"]), "me"), 1)
  }
})

test("reads merge between tabs rather than overwriting another tab's IDs", () => {
  const storage = memoryStorage()
  const a = new ReviewActivityReadState("review", "me", storage)
  const b = new ReviewActivityReadState("review", "me", storage)
  a.markRead([thread([1, "other"])])
  b.markRead([thread([2, "other"])])
  a.refresh()
  assert.equal(a.unread(thread([1, "other"], [2, "other"]), "me"), 0)
})
