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
    return thread.comments.filter(comment => {
      const id = String(comment.id)
      if (!this.seen.has(id) && this.persistent) {
        try {
          if (this.storage.getItem(`${this.key}:comment:${encodeURIComponent(id)}`) === "1") this.seen.add(id)
        } catch {
          this.persistent = false
        }
      }
      return (identityId == null || String(comment.authorId) !== String(identityId)) && !this.seen.has(id)
    }).length
  }

  markRead(threads) {
    for (const thread of threads) {
      for (const comment of thread.comments) {
        const id = String(comment.id)
        this.seen.add(id)
        if (!this.persistent) continue
        try {
          // Independent, immutable records cannot overwrite another tab's reads.
          // Keep the old shared array read-only for previously saved state.
          this.storage.setItem(`${this.key}:comment:${encodeURIComponent(id)}`, "1")
        } catch {
          this.persistent = false
        }
      }
    }
  }
}
