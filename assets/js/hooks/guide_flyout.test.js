import assert from "node:assert/strict"
import { afterEach, test } from "node:test"
import { GuideFlyout } from "./guide_flyout.js"

const realWindow = globalThis.window
const realDocument = globalThis.document

function fakeNode() {
  const attrs = new Map()
  const listeners = new Map()
  const classes = new Set()
  return {
    attrs,
    classes,
    inert: false,
    setAttribute: (name, value) => attrs.set(name, value),
    getAttribute: name => attrs.get(name),
    addEventListener: (type, fn) => listeners.set(type, fn),
    removeEventListener: type => listeners.delete(type),
    dispatch: (type, event = {}) => listeners.get(type)?.({ preventDefault() {}, ...event }),
    focus() {},
    classList: { toggle: (name, on) => (on ? classes.add(name) : classes.delete(name)) },
  }
}

// One browser tab: a window with its own storage, location and listeners,
// shared by every page the reader visits in it.
function fakeTab({ phone }) {
  const listeners = new Map()
  const saved = new Map()
  const sections = fakeNode()
  globalThis.window = {
    location: { pathname: "/r/first" },
    localStorage: { getItem: key => saved.get(key) ?? null, setItem: (key, value) => saved.set(key, value) },
    matchMedia: () => ({ matches: phone }),
    requestAnimationFrame: () => {},
    addEventListener: (type, fn) => listeners.set(type, fn),
    removeEventListener: type => listeners.delete(type),
  }
  globalThis.document = { querySelector: selector => (selector === "[data-quick-sections]" ? sections : null) }
  return {
    saved,
    sections,
    fire: type => listeners.get(type)?.({}),
    goTo: pathname => { window.location.pathname = pathname },
  }
}

function mount() {
  const toggle = fakeNode()
  const panel = fakeNode()
  const el = fakeNode()
  el.querySelector = selector => ({
    "[data-guide-flyout-toggle]": toggle,
    "[data-guide-flyout-panel]": panel,
  })[selector] ?? null
  const hook = Object.assign(Object.create(GuideFlyout), { el })
  hook.mounted()
  return { hook, el, toggle, panel }
}

const isOpen = ({ el, toggle, panel }) => {
  const open = el.classes.has("is-flyout-open")
  assert.equal(toggle.getAttribute("aria-expanded"), String(open))
  assert.equal(panel.inert, !open)
  return open
}

afterEach(() => {
  globalThis.window = realWindow
  globalThis.document = realDocument
})

test("on phones the map closes when a patch moves to another review", () => {
  const tab = fakeTab({ phone: true })
  const page = mount()
  assert.equal(isOpen(page), false)

  page.toggle.dispatch("click")
  assert.equal(isOpen(page), true)
  assert.equal(tab.sections.getAttribute("aria-expanded"), "true")

  // A query change on the same review keeps it open.
  page.hook.updated()
  assert.equal(isOpen(page), true)

  tab.goTo("/r/second")
  tab.fire("phx:page-loading-stop")
  assert.equal(isOpen(page), false)
  assert.equal(tab.sections.getAttribute("aria-expanded"), "false")

  // Back to the first review closes it the same way.
  page.toggle.dispatch("click")
  tab.goTo("/r/first")
  tab.fire("popstate")
  assert.equal(isOpen(page), false)
})

test("on phones a review opened later, after /reviews, starts with the map closed", () => {
  const tab = fakeTab({ phone: true })
  const first = mount()
  first.toggle.dispatch("click")
  assert.equal(isOpen(first), true)
  first.hook.destroyed()
  assert.equal(tab.sections.getAttribute("aria-expanded"), "false")

  tab.goTo("/r/second")
  assert.equal(isOpen(mount()), false)
  assert.equal(tab.saved.size, 0)
})

test("wide screens keep the remembered sidebar state across pages", () => {
  const tab = fakeTab({ phone: false })
  const first = mount()
  assert.equal(isOpen(first), true)
  first.toggle.dispatch("click")
  assert.equal(isOpen(first), false)

  tab.goTo("/r/second")
  tab.fire("phx:page-loading-stop")
  assert.equal(isOpen(first), false)
  assert.equal(isOpen(mount()), false)
})
