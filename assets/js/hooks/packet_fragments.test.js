import assert from "node:assert/strict"
import {test} from "node:test"
import PacketFragments from "./packet_fragments.js"

const setup = hash => {
  const listeners = new Map()
  const events = []
  const requests = []
  globalThis.window = {
    location: new URL(`https://reviews.example/r/test${hash}`),
    addEventListener: (name, fn) => listeners.set(name, fn),
    removeEventListener: name => listeners.delete(name),
    dispatchEvent: event => events.push(event.detail),
  }
  const hook = {
    ...PacketFragments,
    el: {dataset: {patchset: "1"}, addEventListener() {}, removeEventListener() {}},
    pushEvent: (name, payload, reply) => requests.push({name, payload, reply}),
  }
  hook.mounted()
  return {hook, listeners, events, requests}
}

test("direct loads resolve encoded fragments and focus only after the reply", () => {
  const {events, requests} = setup("#packet-section-0-row-%31")
  assert.equal(requests[0].payload.id, "packet-section-0-row-1")
  assert.deepEqual(events, [])
  requests[0].reply({id: "card"})
  assert.deepEqual(events, [{id: "card"}])
})

test("hash changes including back/forward resolve again and stale replies cannot focus", () => {
  const {listeners, events, requests} = setup("#packet-section-0-row-1")
  window.location.hash = "#packet-section-1-row-0"
  listeners.get("hashchange")()
  requests[0].reply({id: "old"})
  requests[1].reply({id: "new"})
  window.location.hash = "#packet-section-0-row-1"
  listeners.get("hashchange")()
  requests[2].reply({id: "old"})
  assert.deepEqual(events, [{id: "new"}, {id: "old"}])
})

test("repeated links resolve again; modified, external, download and new-tab links are untouched", () => {
  const {hook, requests} = setup("#packet-section-0-row-1")
  const click = (props = {}, linkProps = {}) => hook.onClick({
    button: 0, target: {closest: () => ({href: window.location.href, hasAttribute: () => false, ...linkProps})}, ...props,
  })
  click()
  assert.equal(requests.length, 2)
  click({ctrlKey: true})
  click({button: 1})
  click({}, {target: "_blank"})
  click({}, {hasAttribute: () => true})
  click({}, {href: "https://other.example/#packet-section-0-row-1"})
  click({}, {href: "https://reviews.example/r/test?patchset=2#packet-section-0-row-1"})
  assert.equal(requests.length, 2)
})

test("patchset changes and reconnect resolve current fragment; ordinary updates do not", () => {
  const {hook, requests} = setup("#packet-section-0-row-1")
  hook.updated()
  assert.equal(requests.length, 1)
  hook.el.dataset.patchset = "2"
  hook.updated()
  hook.reconnected()
  assert.equal(requests.length, 3)
})

test("malformed and unrelated fragments are ignored; missing targets do not focus", () => {
  for (const hash of ["#packet-section-%ZZ", "#other", ""]) {
    assert.equal(setup(hash).requests.length, 0)
  }
  const {requests, events, hook, listeners} = setup("#packet-section-999-row-0")
  requests[0].reply({id: null})
  hook.destroyed()
  requests[0].reply({id: "late"})
  assert.deepEqual(events, [])
  assert.equal(listeners.size, 0)
})

test("back to the fragment-free overview restores overview without adding history", () => {
  const {listeners, requests} = setup("#packet-section-0-row-1")
  window.location.hash = ""
  listeners.get("hashchange")()
  assert.equal(requests[1].name, "select_packet_overview")
})

test("back from an encoded packet prefix restores Overview", () => {
  const {listeners, requests} = setup("#packet%2Dsection-0-row-1")
  assert.equal(requests[0].payload.id, "packet-section-0-row-1")
  window.location.hash = ""
  listeners.get("hashchange")()
  assert.equal(requests[1]?.name, "select_packet_overview")
})

test("back from a malformed fragment does not change section selection", () => {
  const {listeners, requests} = setup("#packet-section-%ZZ")
  window.location.hash = ""
  listeners.get("hashchange")()
  assert.equal(requests.length, 0)
})
