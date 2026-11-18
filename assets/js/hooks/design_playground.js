// DesignPlayground — mounts the real comment UI from annotation_ui.js with
// sample data on /design/components. Replies, resolving and new comments
// change only this page; nothing is sent to the server.

import {
  commentComposer,
  signInPrompt,
  threadBubble,
  threadStatusBadge,
} from "../diff_renderer/annotation_ui.js"
import { Thread } from "../schemas.js"

const you = { id: -1, username: "you", avatar_url: null }
let nextId = -1

function localComment(body) {
  nextId -= 1
  return { id: nextId, body, author: you, attribution: null, inserted_at: new Date().toISOString() }
}

function mountThread(slot, thread) {
  const ui = {}
  const render = () => {
    slot.replaceChildren(
      threadBubble({
        thread,
        ui,
        // The review page re-renders a thread when the server sends it back
        // with the new comment; do the same once the bubble has closed its
        // composer.
        onReply: (current, body) => {
          current.comments.push(localComment(body))
          queueMicrotask(render)
        },
        onUpdateStatus: (current, status) => {
          current.status = status
          render()
        },
      })
    )
  }
  render()
}

function stack() {
  const node = document.createElement("div")
  node.style.display = "grid"
  node.style.gap = "var(--space-5)"
  return node
}

const demos = {
  threads(el) {
    const threads = Thread.array().parse(JSON.parse(el.dataset.threads))
    const list = stack()
    for (const thread of threads) {
      const slot = document.createElement("div")
      mountThread(slot, thread)
      list.append(slot)
    }
    el.replaceChildren(list)
  },

  composer(el) {
    const list = stack()
    const posted = stack()
    const anchor = { granularity: "line", line_number_hint: 12, context_before: [], context_after: [] }
    const reset = () => {
      list.replaceChildren(
        commentComposer({
          autoFocus: false,
          onCancel: reset,
          onSave: (body) => {
            const thread = {
              id: nextId--, file_path: "demo.ex", side: "new", anchor, status: "open",
              author: you, comments: [localComment(body)], can_update_status: true,
            }
            const slot = document.createElement("div")
            mountThread(slot, thread)
            posted.prepend(slot)
            reset()
          },
        }),
        posted
      )
    }
    reset()
    el.replaceChildren(list)
  },

  "sign-in"(el) {
    el.replaceChildren(signInPrompt(() => {}))
  },

  badges(el) {
    const row = document.createElement("div")
    row.style.display = "flex"
    row.style.flexWrap = "wrap"
    row.style.gap = "var(--space-3)"
    row.append(...["open", "resolved", "outdated"].map(threadStatusBadge))
    el.replaceChildren(row)
  },
}

export default {
  mounted() {
    try {
      demos[this.el.dataset.demo]?.(this.el)
    } catch (err) {
      // eslint-disable-next-line no-console
      console.error("[DesignPlayground] could not mount the sample:", err)
    }
  },
}
