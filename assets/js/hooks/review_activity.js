import { ReviewActivityReadState } from "../lib/review_activity_read_state.js"
import { PHONE } from "../lib/breakpoints.js"

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
    this.onClick = event => {
      if (event.target.closest("[data-quick-sections]")) {
        // The guide's section bar scrolls away on phones; bring it back and
        // open its map, the same as pressing its menu button.
        const guide = document.getElementById("review-guide-shell")
        guide?.scrollIntoView({ block: "start" })
        const map = guide?.querySelector("[data-guide-flyout-toggle]")
        if (map?.getAttribute("aria-expanded") !== "true") map?.click()
        return
      }
      if (event.target.closest("[data-activity-mark-all]")) {
        this.readState.markRead(this.activity.threads)
        this.renderActivity()
        return
      }
      const button = event.target.closest("[data-activity-thread]")
      if (!button || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
      event.preventDefault()
      const thread = this.activity.threads.find(thread => thread.id === button.dataset.activityThread)
      if (!thread) return
      this.readState.markRead([thread])
      this.renderActivity()
      // On phones the open list floats over the code; get out of the way.
      if (window.matchMedia(PHONE).matches) this.details.open = false
      // Navigation owns revealing the section/file, opening the thread and focus.
      window.dispatchEvent(new CustomEvent("reviews:open-thread", {
        detail: { threadId: thread.id, filePath: thread.filePath },
      }))
    }
    this.onStorage = event => {
      if (event.key !== null && event.key !== this.readState.key &&
          !event.key.startsWith(`${this.readState.key}:comment:`)) return
      this.readState.refresh()
      this.renderActivity()
    }
    this.onOpen = event => this.pushEvent("open_activity_thread", { thread_id: event.detail.threadId })
    // On phones the open list floats over the code; a tap elsewhere or
    // Escape closes it.
    const phone = () => window.matchMedia(PHONE).matches
    this.onOutside = event => {
      if (!this.el.contains(event.target) && this.details.open && phone()) this.details.open = false
    }
    this.onKeydown = event => {
      if (event.key !== "Escape" || !this.details.open || !phone()) return
      this.details.open = false
      this.details.querySelector("summary").focus()
    }
    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("keydown", this.onKeydown)
    document.addEventListener("pointerdown", this.onOutside)
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
    const unreadThreads = threads.filter(thread => this.readState.unread(thread, identityId) > 0)
    const count = this.el.querySelector("[data-activity-count]")
    // No count at all beats a "0".
    count.textContent = this.activity.commentCount ? String(this.activity.commentCount) : ""
    count.setAttribute("aria-label", this.activity.commentCount
      ? `${this.activity.commentCount} comments, ${total} unread`
      : "No comments")
    this.details.dataset.unread = String(total > 0)
    this.el.querySelector("[data-activity-empty]").hidden = total > 0
    this.el.querySelector("[data-activity-status]").textContent = `${total} unread comments in ${unreadThreads.length} threads.`
    this.el.querySelector("[data-activity-storage]").textContent = this.readState.persistent
      ? "Read state is saved in this browser, not your account."
      : "Browser storage is unavailable. Read state lasts only while this page is open."
    this.el.querySelector("[data-activity-mark-all]").disabled = total === 0

    const list = this.el.querySelector("[data-activity-list]")
    const focusedId = document.activeElement?.dataset.activityThread
    const existing = new Map([...list.children].map(item => [item.dataset.threadId, item]))
    const keep = new Set(unreadThreads.map(thread => thread.id))
    for (const [id, item] of existing) if (!keep.has(id)) item.remove()
    for (const [index, thread] of unreadThreads.entries()) {
      const unread = this.readState.unread(thread, identityId)
      let item = existing.get(thread.id)
      if (!item) {
        item = document.createElement("li")
        item.dataset.threadId = thread.id
        const button = document.createElement("a")
        button.id = `${this.el.id}-thread-${thread.id}`
        button.className = "review-activity-entry"
        button.dataset.activityThread = thread.id
        item.append(button)
      }
      const button = item.firstElementChild
      button.href = thread.href
      button.title = thread.filePath
      const location = thread.line == null ? "Thread" : `${thread.side === "old" ? "−" : "+"}${thread.line}`
      button.setAttribute("aria-label", `${thread.filePath}, line ${location}, ${unread} unread comments${thread.earlierRevision ? ", earlier revision" : ""}`)
      button.replaceChildren(
        textElement("span", "review-activity-file", thread.filePath),
        textElement("span", "review-activity-location", `${location}${thread.earlierRevision ? " (earlier)" : ""}`),
        textElement("span", "review-activity-read", String(unread)),
      )
      if (list.children[index] !== item) list.insertBefore(item, list.children[index] || null)
    }
    // Moving an existing item in response to a reply can otherwise drop focus.
    if (focusedId) {
      const focused = [...list.querySelectorAll("a")].find(button => button.dataset.activityThread === focusedId)
      ;(focused || this.details.querySelector("summary")).focus({ preventScroll: true })
    }
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("keydown", this.onKeydown)
    document.removeEventListener("pointerdown", this.onOutside)
    window.removeEventListener("storage", this.onStorage)
    window.removeEventListener("reviews:open-thread", this.onOpen)
  },
}

export default ReviewActivity
