import { ReviewActivityReadState } from "../lib/review_activity_read_state.js"
import { WIDE } from "../lib/breakpoints.js"

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
      if (event.target.closest("[data-activity-mark-all]")) {
        this.readState.markRead(this.activity.threads)
        this.renderActivity()
        return
      }
      const button = event.target.closest("[data-activity-thread]")
      if (!button || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
      event.preventDefault()
      const threadId = button.dataset.activityThread
      const thread = this.activity.threads.find(thread => thread.id === threadId)
      if (thread) this.readState.markRead([thread])
      this.renderActivity()
      // Navigation owns revealing the section/file, opening the thread and focus.
      window.dispatchEvent(new CustomEvent("reviews:open-thread", {
        detail: { threadId, filePath: button.dataset.filePath },
      }))
    }
    this.onStorage = event => {
      if (event.key !== null && event.key !== this.readState.key &&
          !event.key.startsWith(`${this.readState.key}:comment:`)) return
      this.readState.refresh()
      this.renderActivity()
    }
    // Collapsing is remembered in this browser; wide screens start open.
    this.openKey = "reviews:activity-open"
    let savedOpen = null
    try { savedOpen = window.localStorage.getItem(this.openKey) } catch { /* optional */ }
    this.details.open = savedOpen === null ? window.matchMedia(WIDE).matches : savedOpen === "true"
    this.details.addEventListener("toggle", () => {
      try { window.localStorage.setItem(this.openKey, String(this.details.open)) } catch { /* optional */ }
      if (this.details.open) this.scrollLogToEnd()
    })
    // The log is a running record of this visit: comments stay in it after
    // they leave the server data, and new ones append.
    this.log = new Map()
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
    const unreadThreads = threads.filter(thread => this.readState.unread(thread, identityId) > 0)
    const count = this.el.querySelector("[data-activity-count]")
    // No count at all beats a "0".
    count.textContent = this.activity.commentCount ? String(this.activity.commentCount) : ""
    count.setAttribute("aria-label", this.activity.commentCount
      ? `${this.activity.commentCount} comments, ${total} unread`
      : "No comments")
    this.details.dataset.unread = String(total > 0)
    this.el.querySelector("[data-activity-status]").textContent = `${total} unread comments in ${unreadThreads.length} threads.`
    this.el.querySelector("[data-activity-storage]").textContent = this.readState.persistent
      ? "Read state is saved in this browser, not your account."
      : "Browser storage is unavailable. Read state lasts only while this page is open."
    this.el.querySelector("[data-activity-mark-all]").disabled = total === 0

    for (const entry of this.activity.log || []) this.log.set(entry.id, entry)
    // No activity renders nothing: no empty panel, no "0".
    this.el.hidden = this.log.size === 0
    this.renderLog()
  },

  renderLog() {
    const { identityId } = this.activity
    const list = this.el.querySelector("[data-activity-list]")
    const atEnd = list.scrollHeight - list.scrollTop - list.clientHeight < 24
    const entries = [...this.log.values()].sort((a, b) =>
      a.insertedAt.localeCompare(b.insertedAt) || Number(a.id) - Number(b.id))
    const existing = new Map([...list.children].map(item => [item.dataset.commentId, item]))
    let added = false
    for (const [index, entry] of entries.entries()) {
      let item = existing.get(entry.id)
      if (!item) {
        item = this.logItem(entry)
        added = true
      }
      const own = identityId != null && entry.authorId === String(identityId)
      const unread = !own && this.readState.unread({ comments: [entry] }, identityId) > 0
      item.classList.toggle("is-unread", unread)
      item.classList.toggle("is-own", own)
      if (list.children[index] !== item) list.insertBefore(item, list.children[index] || null)
    }
    // Follow new comments the way a chat does, unless the reader scrolled up.
    if (added && (atEnd || !this.logRendered)) this.scrollLogToEnd()
    this.logRendered = true
  },

  logItem(entry) {
    const item = document.createElement("li")
    item.dataset.commentId = entry.id
    const link = document.createElement("a")
    link.className = "review-activity-entry"
    link.href = entry.href
    link.dataset.activityThread = entry.threadId
    link.dataset.filePath = entry.filePath
    const file = entry.filePath.split("/").pop()
    const where = entry.line == null ? file : `${file}:${entry.side === "old" ? "−" : "+"}${entry.line}`
    const time = new Date(entry.insertedAt)
    const sameDay = time.toDateString() === new Date().toDateString()
    const stamp = textElement("time", "review-activity-time", time.toLocaleString([], sameDay
      ? { hour: "numeric", minute: "2-digit" }
      : { month: "short", day: "numeric" }))
    stamp.dateTime = entry.insertedAt
    stamp.title = time.toLocaleString()
    const anchor = textElement("span", "review-activity-anchor", where)
    anchor.title = entry.line == null ? entry.filePath : `${entry.filePath}, line ${entry.line}`
    const meta = document.createElement("span")
    meta.className = "review-activity-meta"
    meta.append(textElement("span", "review-activity-author", entry.author), stamp, anchor)
    link.append(meta)
    if (entry.replyTo) {
      const quote = textElement("span", "review-activity-quote", `${entry.replyTo.author}: ${entry.replyTo.body}`)
      link.append(quote)
    }
    link.append(textElement("span", "review-activity-body-text", entry.body))
    link.setAttribute("aria-label", `${entry.author}${entry.replyTo ? ` replied to ${entry.replyTo.author}` : ""} on ${anchor.title}: ${entry.body}`)
    item.append(link)
    return item
  },

  scrollLogToEnd() {
    const list = this.el.querySelector("[data-activity-list]")
    list.scrollTop = list.scrollHeight
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    window.removeEventListener("storage", this.onStorage)
    window.removeEventListener("reviews:open-thread", this.onOpen)
  },
}

export default ReviewActivity
