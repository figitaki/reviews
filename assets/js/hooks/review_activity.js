import { ReviewActivityReadState } from "../lib/review_activity_read_state.js"

function storage() {
  try { return window.localStorage } catch { return null }
}

function textElement(tag, className, text) {
  const element = document.createElement(tag)
  element.className = className
  element.textContent = text
  return element
}

export const ReviewActivity = {
  mounted() {
    this.states = new Map()
    this.details = this.el.querySelector("details")
    this.media = window.matchMedia("(min-width: 1200px)")
    this.onMedia = () => { this.details.open = this.media.matches }
    this.onMedia()
    this.media.addEventListener("change", this.onMedia)
    this.onClick = event => {
      if (event.target.closest("[data-activity-mark-all]")) {
        this.readState.markRead(this.activity.threads)
        this.renderActivity()
        return
      }
      const button = event.target.closest("[data-activity-thread]")
      if (!button) return
      const thread = this.activity.threads.find(thread => thread.id === button.dataset.activityThread)
      if (!thread) return
      this.readState.markRead([thread])
      this.renderActivity()
      // Navigation owns revealing the section/file, opening the thread and focus.
      window.dispatchEvent(new CustomEvent("reviews:open-thread", {
        detail: { threadId: thread.id, filePath: thread.filePath },
      }))
    }
    this.onStorage = event => {
      if (event.key !== this.readState.key && event.key !== null) return
      this.readState.refresh()
      this.renderActivity()
    }
    this.onOpen = event => this.pushEvent("open_activity_thread", { thread_id: event.detail.threadId })
    this.el.addEventListener("click", this.onClick)
    window.addEventListener("reviews:open-thread", this.onOpen)
    window.addEventListener("storage", this.onStorage)
    this.updateActivity()
  },

  updated() { this.updateActivity() },

  updateActivity() {
    this.activity = JSON.parse(this.el.dataset.activity)
    const { reviewId, identityId } = this.activity
    const scope = JSON.stringify([reviewId, identityId])
    if (!this.states.has(scope)) {
      this.states.set(scope, new ReviewActivityReadState(reviewId, identityId, storage()))
    }
    this.readState = this.states.get(scope)
    // Rendering, opening and LiveView updates never acknowledge comments.
    this.renderActivity()
  },

  renderActivity() {
    const { threads, identityId } = this.activity
    const total = threads.reduce((sum, thread) => sum + this.readState.unread(thread, identityId), 0)
    this.el.querySelector("[data-activity-count]").textContent = `${total} unread`
    this.el.querySelector("[data-activity-status]").textContent = threads.length === 0
      ? "No comments yet."
      : `${total} unread ${total === 1 ? "comment" : "comments"} from others. Recent threads, newest first.`
    this.el.querySelector("[data-activity-storage]").textContent = this.readState.persistent
      ? "Read state is saved in this browser, not your account."
      : "Browser storage is unavailable. Read state lasts only while this page is open."
    this.el.querySelector("[data-activity-mark-all]").disabled = total === 0

    const list = this.el.querySelector("[data-activity-list]")
    const focusedId = document.activeElement?.dataset.activityThread
    const existing = new Map([...list.children].map(item => [item.dataset.threadId, item]))
    const keep = new Set(threads.map(thread => thread.id))
    for (const [id, item] of existing) if (!keep.has(id)) item.remove()
    for (const [index, thread] of threads.entries()) {
      const unread = this.readState.unread(thread, identityId)
      let item = existing.get(thread.id)
      if (!item) {
        item = document.createElement("li")
        item.dataset.threadId = thread.id
        const button = document.createElement("button")
        button.type = "button"
        button.id = `${this.el.id}-thread-${thread.id}`
        button.className = "review-activity-entry"
        button.dataset.activityThread = thread.id
        item.append(button)
      }
      const button = item.firstElementChild
      button.dataset.unread = String(unread > 0)
      const date = new Date(thread.insertedAt)
      const time = textElement("time", "review-activity-time", date.toLocaleString())
      time.dateTime = thread.insertedAt
      button.replaceChildren(
        textElement("span", "review-activity-file", thread.filePath),
        textElement("span", "review-activity-meta", `${thread.author} · ${thread.status}`),
        textElement("span", "review-activity-preview", thread.preview),
        time,
        textElement("span", "review-activity-read", unread > 0 ? `${unread} unread` : "Read"),
      )
      if (list.children[index] !== item) list.insertBefore(item, list.children[index] || null)
    }
    // Moving an existing item in response to a reply can otherwise drop focus.
    if (focusedId) {
      const focused = [...list.querySelectorAll("button")].find(button => button.dataset.activityThread === focusedId)
      focused?.focus({ preventScroll: true })
    }
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    window.removeEventListener("storage", this.onStorage)
    window.removeEventListener("reviews:open-thread", this.onOpen)
    this.media.removeEventListener("change", this.onMedia)
  },
}

export default ReviewActivity
