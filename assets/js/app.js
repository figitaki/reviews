// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/reviews"
import topbar from "../vendor/topbar"
import ChangesFileTree from "./hooks/changes_file_tree"
import CodeView from "./hooks/code_view"
import DiffRenderer from "./hooks/diff_renderer"
import PacketNavTree from "./hooks/packet_nav_tree"
import StickyHunkHeader from "./hooks/sticky_hunk_header"
import StickyProse from "./hooks/sticky_prose"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ChangesFileTree, CodeView, DiffRenderer, PacketNavTree, StickyHunkHeader, StickyProse},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

const cssPx = (el, property) => {
  const styles = window.getComputedStyle(el)
  const value = Number.parseFloat(styles.getPropertyValue(property) || styles[property])
  return Number.isFinite(value) ? value : 0
}

const prefersReducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches

let scrollAnimationFrame = null

const scrollToTop = top => {
  if (scrollAnimationFrame) window.cancelAnimationFrame(scrollAnimationFrame)

  if (prefersReducedMotion()) {
    window.scrollTo({top, behavior: "auto"})
    return
  }

  const start = window.scrollY || window.pageYOffset || document.documentElement.scrollTop || 0
  const distance = top - start

  if (Math.abs(distance) < 2) {
    window.scrollTo({top, behavior: "auto"})
    return
  }

  const duration = Math.min(220, Math.max(120, Math.abs(distance) * 0.18))
  const startedAt = window.performance.now()

  const tick = now => {
    const progress = Math.min(1, (now - startedAt) / duration)
    const eased = 1 - Math.pow(1 - progress, 3)

    window.scrollTo({top: start + distance * eased, behavior: "auto"})

    if (progress < 1) {
      scrollAnimationFrame = window.requestAnimationFrame(tick)
    } else {
      scrollAnimationFrame = null
    }
  }

  scrollAnimationFrame = window.requestAnimationFrame(tick)
}

const targetScrollOffset = target => {
  const hunkHeader = target.matches(".review-hunk-summary")
    ? target
    : target.querySelector?.(".review-hunk-summary") || target.closest(".review-hunk-card")?.querySelector(".review-hunk-summary")

  if (hunkHeader) return cssPx(hunkHeader, "top") + 8

  const scrollMarginTop = Number.parseFloat(window.getComputedStyle(target).scrollMarginTop)
  if (Number.isFinite(scrollMarginTop) && scrollMarginTop > 0) return scrollMarginTop

  const reviewPage = target.closest(".review-page") || document.documentElement

  if (target.closest(".review-packet-section")) return cssPx(reviewPage, "--review-main-nav-h") + 8

  return 16
}

const scrollToReviewTarget = (target, {highlight = false} = {}) => {
  if (!target.hasAttribute("tabindex")) target.setAttribute("tabindex", "-1")

  const scrollTop = window.scrollY || window.pageYOffset || document.documentElement.scrollTop || 0
  const top = Math.max(0, target.getBoundingClientRect().top + scrollTop - targetScrollOffset(target))

  scrollToTop(top)
  target.focus({preventScroll: true})

  if (!highlight) return

  target.classList.remove("is-packet-nav-target")
  void target.offsetWidth
  target.classList.add("is-packet-nav-target")
  window.setTimeout(() => target.classList.remove("is-packet-nav-target"), 1200)
}

const scrollToReviewTargetId = (id, options = {}, attempts = 12) => {
  const target = document.getElementById(id)

  if (target) {
    scrollToReviewTarget(target, options)
    return
  }

  if (attempts <= 0) return

  window.requestAnimationFrame(() => scrollToReviewTargetId(id, options, attempts - 1))
}

window.addEventListener("phx:packet_nav_jump", ({detail}) => {
  if (!detail?.id) return

  window.requestAnimationFrame(() => scrollToReviewTargetId(detail.id, {highlight: true}))
})

window.addEventListener("phx:hunk_collapsed", ({detail}) => {
  if (!detail?.id) return

  window.requestAnimationFrame(() => {
    window.requestAnimationFrame(() => scrollToReviewTargetId(detail.id))
  })
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
