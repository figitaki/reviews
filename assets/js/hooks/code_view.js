// CodeView — Phoenix LiveView hook for the Changes view. Mounts one
// @pierre/diffs CodeView and feeds it diff payloads that the server streams
// over the socket in batches. The element is `phx-update="ignore"`; all
// updates flow through pushed events.

import { CodeViewRenderer } from "../diff_renderer/code_view_renderer.js"
import { CreateCommentPayload, Thread } from "../schemas.js"

function parseThreads(raw) {
  try {
    return Thread.array().parse(raw ?? [])
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error("[CodeView] invalid threads payload:", err, raw)
    return []
  }
}

const CodeView = {
  mounted() {
    const ds = this.el.dataset
    const signedIn = ds.signedIn === "true"
    const diffStyle = ds.diffStyle === "unified" ? "unified" : "split"

    const onCreateComment = (payload) => {
      try {
        this.pushEvent("create_comment", CreateCommentPayload.parse(payload))
      } catch (err) {
        // eslint-disable-next-line no-console
        console.error("[CodeView] invalid create_comment payload:", err, payload)
      }
    }

    this._renderer = new CodeViewRenderer({
      container: this.el,
      signedIn,
      diffStyle,
      onCreateComment,
    })
    this._renderer.setup()

    // Server streams diff payloads in batches.
    this.handleEvent("code_view:add_items", (payload) => {
      const items = (payload?.items || []).map((item) => ({
        ...item,
        threads: parseThreads(item?.threads),
      }))
      this._renderer?.addItems(items)
    })

    this.handleEvent("code_view:update_threads", (payload) => {
      if (!payload?.file_path) return
      this._renderer?.updateThreads(payload.file_path, parseThreads(payload.threads))
    })

    this.handleEvent("code_view:set_diff_style", (payload) => {
      this._renderer?.setDiffStyle(payload?.style)
    })

    this.handleEvent("code_view:scroll_to", (payload) => {
      if (payload?.file_path) this._renderer?.scrollToFile(payload.file_path)
    })

    this.handleEvent("code_view:reset", () => {
      this._renderer?.reset()
    })

    this._themeObserver = new MutationObserver(() => this._renderer?.refreshTheme())
    this._themeObserver.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    })
    this._systemThemeQuery = window.matchMedia?.("(prefers-color-scheme: dark)")
    this._systemThemeListener = () => {
      if (!document.documentElement.dataset.theme) this._renderer?.refreshTheme()
    }
    this._systemThemeQuery?.addEventListener?.("change", this._systemThemeListener)

    // Handshake: tell the server the renderer is live so streaming can start.
    // This avoids racing the first batch against hook mount.
    this.pushEvent("code_view_ready", {})
  },

  updated() {
    // The container is phx-update="ignore"; refreshes flow through push events.
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

export default CodeView
