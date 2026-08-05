// DiffRenderer — Phoenix LiveView hook wiring for one vanilla @pierre/diffs
// renderer per mounted file. Rendering details live in ../diff_renderer/*.

import { VanillaDiffRenderer } from "../diff_renderer/vanilla_renderer.js"
import {
  compactHunkPayload,
  hunkUIFromDataset,
} from "../diff_renderer/hunk_controls.js"
import { Thread, CreateCommentPayload } from "../schemas.js"

function parseInitial(text, schema) {
  try {
    const json = JSON.parse(text || "[]")
    return schema.array().parse(json)
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error("[DiffRenderer] failed to parse payload:", err)
    return []
  }
}

const DiffRenderer = {
  mounted() {
    const ds = this.el.dataset
    const filePath = ds.filePath
    const signedIn = ds.signedIn === "true"
    const rawDiff = ds.rawDiff || ""
    const initialDiffStyle = ds.diffStyle === "unified" ? "unified" : "split"
    const initialThreads = parseInitial(ds.threads, Thread)
    const hunkUI = hunkUIFromDataset(ds)

    const onCreateComment = (payload) => {
      try {
        const parsed = CreateCommentPayload.parse(payload)
        this.pushEvent("create_comment", parsed)
      } catch (err) {
        // eslint-disable-next-line no-console
        console.error("[DiffRenderer] invalid create_comment payload:", err, payload)
      }
    }

    this._renderer = new VanillaDiffRenderer({
      container: this.el,
      filePath,
      rawDiff,
      signedIn,
      threads: initialThreads,
      diffStyle: initialDiffStyle,
      onCreateComment,
      hunkUI,
      onToggleHunk: () => {
        this.pushEvent("toggle_hunk_diff", { hunk_id: hunkUIFromDataset(this.el.dataset).hunkId })
      },
      onSetHunkViewed: (viewed) => {
        const next = hunkUIFromDataset(this.el.dataset)
        this.pushEvent(
          viewed ? "mark_hunk_viewed" : "mark_hunk_unviewed",
          compactHunkPayload(next.payload)
        )
      },
    })
    this._renderer.render()

    this.handleEvent(`threads_updated:${filePath}`, (raw) => {
      try {
        const threads = Thread.array().parse(raw?.threads ?? [])
        this._renderer?.update({ threads })
      } catch (err) {
        // eslint-disable-next-line no-console
        console.error("[DiffRenderer] invalid threads_updated payload:", err, raw)
      }
    })

    this.handleEvent(`diff_style_updated:${filePath}`, (raw) => {
      const style = raw?.style === "unified" ? "unified" : "split"
      this._renderer?.updateStyle(style)
    })

    this._themeObserver = new MutationObserver(() => this._renderer?.render())
    this._themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    })
    this._systemThemeQuery = window.matchMedia?.("(prefers-color-scheme: dark)")
    this._systemThemeListener = () => {
      if (!document.documentElement.dataset.theme) this._renderer?.render()
    }
    this._systemThemeQuery?.addEventListener?.("change", this._systemThemeListener)

    // The "Open Threads" sidebar dispatches reviews:scroll-to-anchor on click.
    // Pierre rows live inside shadow DOM, so the pre-Pierre direct DOM lookup is
    // intentionally still not restored here.
  },

  updated() {
    this._renderer?.updateHunkUI(hunkUIFromDataset(this.el.dataset))
  },

  destroyed() {
    this._themeObserver?.disconnect()
    this._themeObserver = null
    this._systemThemeQuery?.removeEventListener?.("change", this._systemThemeListener)
    this._systemThemeQuery = null
    this._systemThemeListener = null
    this._renderer?.cleanUp()
    this._renderer = null
  },
}

export default DiffRenderer
