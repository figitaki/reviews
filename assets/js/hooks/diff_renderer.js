// DiffRenderer — Phoenix LiveView hook wiring for one vanilla @pierre/diffs
// renderer per mounted file. Rendering details live in ../diff_renderer/*.
//
// The island's `data-*` attributes are the live state channel from LiveView
// (attributes are patched even under phx-update="ignore"). They are validated
// and coerced exactly once, here, by the HunkIslandDataset schema.

import { VanillaDiffRenderer } from "../diff_renderer/vanilla_renderer.js"
import {
  Thread,
  CreateCommentPayload,
  UpdateThreadStatusPayload,
  HunkIslandDataset,
  hunkViewPayload,
} from "../schemas.js"

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

function parseIsland(dataset) {
  try {
    return HunkIslandDataset.parse({ ...dataset })
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error("[DiffRenderer] invalid hunk island dataset:", err)
    return null
  }
}

const DiffRenderer = {
  mounted() {
    const ds = this.el.dataset
    const filePath = ds.filePath
    const signedIn = ds.signedIn === "true"
    const rawDiff = ds.rawDiff || ""
    const initialThreads = parseInitial(ds.threads, Thread)
    this._island = parseIsland(ds)
    const initialDiffStyle = this._island?.diffStyle ?? "split"

    const onCreateComment = (payload) => {
      try {
        const parsed = CreateCommentPayload.parse(payload)
        this.pushEvent("create_comment", parsed)
      } catch (err) {
        // eslint-disable-next-line no-console
        console.error("[DiffRenderer] invalid create_comment payload:", err, payload)
      }
    }

    const onUpdateThreadStatus = (payload) => {
      try {
        const parsed = UpdateThreadStatusPayload.parse(payload)
        this.pushEvent("update_thread_status", parsed)
      } catch (err) {
        // eslint-disable-next-line no-console
        console.error("[DiffRenderer] invalid update_thread_status payload:", err, payload)
      }
    }

    const onToggleHunk = () => {
      if (!this._island) return
      this.pushEvent("toggle_hunk_diff", { hunk_id: this._island.hunkId })
    }

    const onSetHunkViewed = (viewed) => {
      if (!this._island) return
      try {
        const payload = hunkViewPayload(this._island)
        this.pushEvent(viewed ? "mark_hunk_viewed" : "mark_hunk_unviewed", payload)
      } catch (err) {
        // eslint-disable-next-line no-console
        console.error("[DiffRenderer] invalid hunk view payload:", err)
      }
    }

    this._renderer = new VanillaDiffRenderer({
      container: this.el,
      filePath,
      rawDiff,
      signedIn,
      threads: initialThreads,
      diffStyle: initialDiffStyle,
      hunkUI: this._island,
      onCreateComment,
      onUpdateThreadStatus,
      onToggleHunk,
      onSetHunkViewed,
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

    this.handleEvent("open_review_thread", ({ thread_id, file_path }) => {
      if (file_path === filePath) this._renderer?.openThread(thread_id)
    })
  },

  updated() {
    // Children are phx-update="ignore"; only the data-* attributes change.
    // The dataset is the single state channel: diff style and hunk UI state
    // both sync from the patched attributes.
    this._island = parseIsland(this.el.dataset)
    if (!this._island) return
    this._renderer?.updateStyle(this._island.diffStyle)
    this._renderer?.updateHunkUI(this._island)
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
