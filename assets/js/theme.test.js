import {test, expect} from "bun:test"
import {readFileSync} from "node:fs"
import {runInNewContext} from "node:vm"

const script = readFileSync(new URL("./theme.js", import.meta.url), "utf8")
const boot = (saved = null) => {
  const attributes = new Map()
  const storage = new Map(saved ? [["phx:theme", saved]] : [])
  const listeners = {}
  const buttons = ["light", "dark", "system"].map(theme => ({
    dataset: {phxTheme: theme},
    setAttribute(name, value) { this[name] = value },
  }))
  const document = {
    documentElement: {
      hasAttribute: key => attributes.has(key),
      setAttribute: (key, value) => attributes.set(key, value),
      removeAttribute: key => attributes.delete(key),
    },
    querySelectorAll: () => buttons,
    addEventListener: (name, fn) => { listeners[name] = fn },
  }
  runInNewContext(script, {
    document,
    localStorage: {
      getItem: key => storage.get(key) ?? null,
      setItem: (key, value) => storage.set(key, value),
      removeItem: key => storage.delete(key),
    },
    window: {addEventListener: (name, fn) => { listeners[name] = fn }},
  })
  return {attributes, storage, listeners, buttons}
}

for (const theme of ["light", "dark"]) {
  test(`${theme} is applied synchronously before DOMContentLoaded`, () => {
    const state = boot(theme)
    expect(state.attributes.get("data-theme")).toBe(theme)
    state.listeners.DOMContentLoaded()
    expect(state.buttons.find(button => button.dataset.phxTheme === theme)["aria-pressed"]).toBe("true")
  })
}

test("system clears explicit theme and cross-tab/toggle changes stay in sync", () => {
  const state = boot()
  expect(state.attributes.has("data-theme")).toBe(false)
  state.listeners["phx:set-theme"]({target: {dataset: {phxTheme: "dark"}}})
  expect(state.storage.get("phx:theme")).toBe("dark")
  state.listeners.storage({key: "phx:theme", newValue: "light"})
  expect(state.attributes.get("data-theme")).toBe("light")
  state.listeners.storage({key: "phx:theme", newValue: null})
  expect(state.attributes.has("data-theme")).toBe(false)
  expect(state.buttons[2]["aria-pressed"]).toBe("true")
})
