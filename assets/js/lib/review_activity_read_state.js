// Store exact observed comment IDs, not timestamps or thread-only booleans:
// a reply arriving after an explicit read action must remain unread.
export class ReviewActivityReadState {
  constructor(reviewId, identityId, storage) {
    this.key = `reviews:activity:v1:${encodeURIComponent(reviewId)}:${identityId == null ? "anonymous" : `identity-${encodeURIComponent(identityId)}`}`
    this.storage = storage
    this.seen = new Set()
    this.persistent = Boolean(storage)
    this.refresh()
  }

  refresh() {
    if (!this.persistent) return
    try {
      const raw = this.storage.getItem(this.key)
      const ids = raw == null ? [] : JSON.parse(raw)
      if (!Array.isArray(ids) || !ids.every(id => typeof id === "string")) return
      for (const id of ids) this.seen.add(id)
    } catch {
      // Retain in-memory state if storage is blocked, corrupt, or over quota.
      this.persistent = false
    }
  }

  unread(thread, identityId) {
    return thread.comments.filter(comment =>
      (identityId == null || String(comment.authorId) !== String(identityId)) &&
      !this.seen.has(String(comment.id))
    ).length
  }

  markRead(threads) {
    this.refresh() // Merge other tabs' reads before writing.
    for (const thread of threads) {
      for (const comment of thread.comments) this.seen.add(String(comment.id))
    }
    if (!this.persistent) return
    try {
      this.storage.setItem(this.key, JSON.stringify([...this.seen]))
    } catch {
      this.persistent = false
    }
  }
}
