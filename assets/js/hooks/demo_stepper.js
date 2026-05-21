// IntersectionObserver-driven chapter stepper for the homepage workflow demo.
//
// Each chapter on /home has a small sentinel element with `phx-hook="DemoStepper"`
// and a `data-demo-step="push|review|reprompt|revise"` attribute. When the sentinel
// scrolls into the middle band of the viewport, the hook pushes `set_demo_step`
// to the LiveView, which morphs the sticky packet preview to the matching state.
//
// Under prefers-reduced-motion the hook skips registration; the LiveView template
// still renders a usable terminal state via the .home-demo data-step="revise"
// fallback CSS.

const REDUCED_MOTION = () =>
  typeof window !== "undefined" && window.matchMedia?.("(prefers-reduced-motion: reduce)").matches

let sharedObserver = null
const targets = new Map() // element -> hook instance
// Dedupe consecutive identical pushes across the whole stepper. Per-hook
// dedupe is wrong: each hook only ever pushes its own step value, so a
// per-hook flag becomes "fired once, never again" — which kills the demo
// the moment the reader scrolls back up.
let lastStep = null

function ensureObserver() {
  if (sharedObserver) return sharedObserver
  if (typeof window === "undefined" || !("IntersectionObserver" in window)) return null

  sharedObserver = new IntersectionObserver(
    entries => {
      // Among the entries that changed this tick, prefer the one whose
      // center is closest to the viewport's vertical middle. Then re-survey
      // the OTHER observed targets too — a forward scroll may stop the
      // observer from firing for a previous target that no longer crosses
      // a threshold, and we still want it considered.
      const candidates = new Set(entries.map(e => e.target))
      for (const el of targets.keys()) candidates.add(el)

      let best = null
      let bestDistance = Infinity

      for (const el of candidates) {
        const rect = el.getBoundingClientRect()
        // Skip elements entirely above or below the viewport.
        if (rect.bottom < 0 || rect.top > window.innerHeight) continue
        const center = rect.top + rect.height / 2
        const distance = Math.abs(center - window.innerHeight / 2)
        if (distance < bestDistance) {
          best = el
          bestDistance = distance
        }
      }

      if (!best) return
      const hook = targets.get(best)
      if (!hook) return

      const step = best.dataset.demoStep
      if (!step) return
      if (lastStep === step) return
      lastStep = step
      hook.pushEvent("set_demo_step", {step})
    },
    {
      // Middle 60% of the viewport — keeps the demo "active" while the chapter
      // body is the dominant content on screen.
      rootMargin: "-20% 0px -20% 0px",
      threshold: [0, 0.5, 1],
    },
  )

  return sharedObserver
}

const DemoStepper = {
  mounted() {
    if (REDUCED_MOTION()) return
    const observer = ensureObserver()
    if (!observer) return

    targets.set(this.el, this)
    observer.observe(this.el)
  },

  destroyed() {
    if (sharedObserver && targets.has(this.el)) {
      sharedObserver.unobserve(this.el)
      targets.delete(this.el)
    }
  },
}

export default DemoStepper
