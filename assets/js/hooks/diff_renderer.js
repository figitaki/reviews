// DiffRenderer — Phoenix LiveView hook that mounts a React island per file.
//
// Each per-file <div phx-hook="DiffRenderer" phx-update="ignore"> carries
// `data-*` props (see docs/CONTRACTS.md). The hook reads those, mounts a
// React tree inside `this.el`, and bridges UI events back to LiveView via
// pushEvent.
//
// The island keeps diff rendering local so thread anchors and draft composers
// stay simple. Syntax highlighting is applied per rendered row with Shiki.

import React, { useState, useRef, useEffect, useMemo } from "react"
import { createRoot } from "react-dom/client"
import { codeToTokens } from "shiki"

const SHIKI_THEME = "github-dark-default"

// ----------------------------------------------------------------------------
// Parsing — split a single file's unified diff into rows we can render.
// We do this in plain JS to avoid the @pierre/diffs worker dance for v1.
// Each row is `{ type, oldNumber, newNumber, content }`.
// ----------------------------------------------------------------------------

function parseUnifiedDiff(rawDiff) {
  if (!rawDiff) return { rows: [], language: "text" }

  const lines = rawDiff.split("\n")
  const rows = []
  let oldNum = 0
  let newNum = 0
  let inHunk = false

  for (const line of lines) {
    if (line.startsWith("@@")) {
      const m = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/)
      if (m) {
        oldNum = parseInt(m[1], 10)
        newNum = parseInt(m[2], 10)
        inHunk = true
        rows.push({ type: "hunk", oldNumber: null, newNumber: null, content: line })
      }
      continue
    }
    if (!inHunk) continue
    if (line.startsWith("+++") || line.startsWith("---")) continue

    if (line.startsWith("+")) {
      rows.push({ type: "add", oldNumber: null, newNumber: newNum, content: line.slice(1) })
      newNum += 1
    } else if (line.startsWith("-")) {
      rows.push({ type: "del", oldNumber: oldNum, newNumber: null, content: line.slice(1) })
      oldNum += 1
    } else if (line.startsWith(" ") || line === "") {
      rows.push({
        type: "ctx",
        oldNumber: oldNum,
        newNumber: newNum,
        content: line.startsWith(" ") ? line.slice(1) : line,
      })
      oldNum += 1
      newNum += 1
    }
    // `\ No newline at end of file` and similar are skipped.
  }

  return { rows }
}

function buildContextSnapshot(rows, anchorIndex, n = 2) {
  const before = []
  for (let i = anchorIndex - 1; i >= 0 && before.length < n; i--) {
    if (rows[i].type === "hunk") break
    before.unshift(rows[i].content)
  }
  const after = []
  for (let i = anchorIndex + 1; i < rows.length && after.length < n; i++) {
    if (rows[i].type === "hunk") break
    after.push(rows[i].content)
  }
  return { before, after }
}

function languageForFile(path) {
  const lower = (path || "").toLowerCase()
  const name = lower.split("/").pop() || ""

  if (name === ".env" || name.startsWith(".env.")) return "dotenv"
  if (name === "mix.exs") return "elixir"
  if (name === "mix.lock") return "elixir"
  if (name.endsWith(".ex") || name.endsWith(".exs")) return "elixir"
  if (name.endsWith(".heex") || name.endsWith(".html.heex")) return "html"
  if (name.endsWith(".js") || name.endsWith(".mjs") || name.endsWith(".cjs")) return "javascript"
  if (name.endsWith(".jsx")) return "jsx"
  if (name.endsWith(".ts")) return "typescript"
  if (name.endsWith(".tsx")) return "tsx"
  if (name.endsWith(".css")) return "css"
  if (name.endsWith(".json")) return "json"
  if (name.endsWith(".md") || name.endsWith(".markdown")) return "markdown"
  if (name.endsWith(".yml") || name.endsWith(".yaml")) return "yaml"
  if (name.endsWith(".toml")) return "toml"
  if (name.endsWith(".sh") || name.endsWith(".bash") || name.endsWith(".zsh")) return "bash"

  return null
}

function tokenStyle(token) {
  const style = {}
  if (token.color) style.color = token.color
  if (token.fontStyle) {
    if (token.fontStyle & 1) style.fontStyle = "italic"
    if (token.fontStyle & 2) style.fontWeight = 700
    if (token.fontStyle & 4) style.textDecoration = "underline"
  }
  return style
}

// Returns an array of {start, end} half-open ranges identifying substrings
// of `content` that some anchor (thread or draft with granularity:"token_range")
// points to. `selection_offset` is used as a hint to disambiguate when the
// substring repeats; falls back to the first occurrence.
function computeAnchorRanges(content, items) {
  const out = []
  if (!content || !items?.length) return out
  for (const item of items) {
    const a = item.anchor
    if (!a || a.granularity !== "token_range") continue
    const sel = a.selection_text
    if (!sel) continue
    let start = -1
    if (Number.isInteger(a.selection_offset)) {
      if (content.slice(a.selection_offset, a.selection_offset + sel.length) === sel) {
        start = a.selection_offset
      }
    }
    if (start < 0) start = content.indexOf(sel)
    if (start < 0) continue
    out.push({ start, end: start + sel.length })
  }
  // Sort + merge overlapping ranges so we don't double-wrap.
  out.sort((a, b) => a.start - b.start)
  const merged = []
  for (const r of out) {
    const last = merged[merged.length - 1]
    if (last && r.start <= last.end) last.end = Math.max(last.end, r.end)
    else merged.push({ ...r })
  }
  return merged
}

// True if any portion of [offset, offset+len) overlaps any anchor range.
function isAnchored(offset, len, anchorRanges) {
  for (const r of anchorRanges) {
    if (offset < r.end && offset + len > r.start) return true
  }
  return false
}

// Split a Shiki token at any anchor-range boundaries that fall inside it.
// Each returned piece is { text, anchored }.
function splitTokenAtRanges(text, offset, anchorRanges) {
  const boundaries = new Set([0, text.length])
  for (const r of anchorRanges) {
    const localStart = r.start - offset
    const localEnd = r.end - offset
    if (localStart > 0 && localStart < text.length) boundaries.add(localStart)
    if (localEnd > 0 && localEnd < text.length) boundaries.add(localEnd)
  }
  const sorted = [...boundaries].sort((a, b) => a - b)
  const pieces = []
  for (let i = 0; i < sorted.length - 1; i++) {
    const start = sorted[i]
    const end = sorted[i + 1]
    if (start === end) continue
    pieces.push({
      text: text.slice(start, end),
      anchored: isAnchored(offset + start, end - start, anchorRanges),
    })
  }
  return pieces
}

// ----------------------------------------------------------------------------
// Bubble helpers: relative time, anchor pinpoint, comment grouping, avatar
// ----------------------------------------------------------------------------

// @example formatRelative("2025-11-08T12:00:00Z", Date.parse("2025-11-08T14:00:00Z"))
//   => { relative: "2 hours ago", absolute: "2025-11-08T12:00:00.000Z" }
// @example formatRelative(null) => { relative: "", absolute: "" }
export function formatRelative(iso, now = Date.now()) {
  if (!iso) return { relative: "", absolute: "" }
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return { relative: "", absolute: "" }
  const diffMs = t - now
  const absSec = Math.round(Math.abs(diffMs) / 1000)
  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" })
  const units = [
    ["year", 60 * 60 * 24 * 365],
    ["month", 60 * 60 * 24 * 30],
    ["week", 60 * 60 * 24 * 7],
    ["day", 60 * 60 * 24],
    ["hour", 60 * 60],
    ["minute", 60],
    ["second", 1],
  ]
  for (const [unit, sec] of units) {
    if (absSec >= sec || unit === "second") {
      const v = Math.round(diffMs / 1000 / sec)
      return {
        relative: rtf.format(v, unit),
        absolute: new Date(t).toISOString(),
      }
    }
  }
  return { relative: "", absolute: "" }
}

// @example anchorPinpoint({granularity:"line",line_number_hint:3}, "old") => "line 3 · old"
// @example anchorPinpoint({granularity:"token_range",line_number_hint:3,selection_text:"FOO"}, "new") => "line 3 · FOO"
export function anchorPinpoint(anchor, side) {
  if (!anchor) return null
  const line = anchor.line_number_hint
  if (anchor.granularity === "token_range" && anchor.selection_text) {
    return `line ${line} · ${anchor.selection_text}`
  }
  return `line ${line} · ${side === "old" ? "old" : "new"}`
}

// @example groupCommentsByAuthor([{author:{id:1}},{author:{id:1}},{author:{id:2}}])
//   => [{authorId:1, comments:[2]},{authorId:2, comments:[1]}]
export function groupCommentsByAuthor(comments) {
  const out = []
  for (const c of comments || []) {
    const authorId = c.author?.id ?? null
    const last = out[out.length - 1]
    if (last && last.authorId === authorId) {
      last.comments.push(c)
    } else {
      out.push({ authorId, author: c.author, comments: [c] })
    }
  }
  return out
}

function Avatar({ user, size = 20 }) {
  if (!user) return null
  if (user.avatar_url) {
    return (
      <img
        className="rdr-avatar"
        src={user.avatar_url}
        alt=""
        width={size}
        height={size}
        loading="lazy"
        decoding="async"
      />
    )
  }
  const initial = (user.username || "?").slice(0, 1).toUpperCase()
  return (
    <span
      className="rdr-avatar rdr-avatar-fallback"
      style={{ width: size, height: size }}
      aria-hidden="true"
    >
      {initial}
    </span>
  )
}

function flashRow(fileId, rowIndex) {
  const el = document.getElementById(`file-${fileId}-row-${rowIndex}`)
  if (!el) return
  el.scrollIntoView({ behavior: "smooth", block: "center" })
  el.classList.add("rdr-row-flash")
  window.setTimeout(() => el.classList.remove("rdr-row-flash"), 1200)
}

function HighlightedCode({ content, tokens, anchorRanges }) {
  const ranges = anchorRanges || []
  // Plain-text fallback (no Shiki tokens available for this line).
  if (!tokens || tokens.length === 0) {
    if (ranges.length === 0) return content
    const pieces = splitTokenAtRanges(content, 0, ranges)
    return pieces.map((p, i) =>
      p.anchored ? (
        <mark key={i} className="rdr-token-anchor">{p.text}</mark>
      ) : (
        <React.Fragment key={i}>{p.text}</React.Fragment>
      )
    )
  }

  const out = []
  let offset = 0
  let key = 0
  for (const token of tokens) {
    const style = tokenStyle(token)
    const pieces = ranges.length
      ? splitTokenAtRanges(token.content, offset, ranges)
      : [{ text: token.content, anchored: false }]
    for (const p of pieces) {
      if (p.anchored) {
        out.push(
          <mark key={key++} className="rdr-token-anchor" style={style}>
            {p.text}
          </mark>
        )
      } else {
        out.push(
          <span key={key++} style={style}>
            {p.text}
          </span>
        )
      }
    }
    offset += token.content.length
  }
  return out
}

function LineNumber({ number, side, interactive, onClick }) {
  if (!number) {
    return <span className="rdr-line-number" aria-hidden="true" />
  }

  if (!interactive) {
    return <span className="rdr-line-number">{number}</span>
  }

  return (
    <button
      type="button"
      className="rdr-line-number rdr-line-number-clickable"
      aria-label={`Add comment on ${side} line ${number}`}
      onClick={onClick}
    >
      {number}
    </button>
  )
}

// ----------------------------------------------------------------------------
// React components
// ----------------------------------------------------------------------------

function ThreadBubble({ thread, onScrollToAnchor, onReply }) {
  const [replying, setReplying] = useState(false)
  const runs = useMemo(() => groupCommentsByAuthor(thread.comments), [thread.comments])

  return (
    <div
      className="rdr-thread"
      data-thread-id={thread.id}
      role="group"
      aria-label={`Thread by ${thread.author?.username || "reviewer"}`}
    >
      <button
        type="button"
        className="rdr-thread-anchor-link"
        onClick={onScrollToAnchor}
        title="Jump to source line"
      >
        <span className="rdr-anchor-pinpoint">
          {anchorPinpoint(thread.anchor, thread.side)}
        </span>
        {thread.status ? (
          <span className={`rdr-status-pill rdr-status-${thread.status}`}>
            {thread.status}
          </span>
        ) : null}
      </button>

      <ul className="rdr-thread-comments">
        {runs.map((run, ri) => (
          <li key={ri} className="rdr-thread-run">
            <header className="rdr-thread-run-header">
              <Avatar user={run.author} />
              <span className="rdr-thread-author">
                {run.author?.username || "reviewer"}
              </span>
            </header>
            <ul className="rdr-thread-run-comments">
              {run.comments.map((c) => {
                const { relative, absolute } = formatRelative(c.inserted_at)
                return (
                  <li key={c.id} className="rdr-thread-comment">
                    <div className="rdr-thread-comment-body">{c.body}</div>
                    {relative ? (
                      <time
                        className="rdr-thread-comment-time"
                        dateTime={absolute}
                        title={absolute}
                      >
                        {relative}
                      </time>
                    ) : null}
                  </li>
                )
              })}
            </ul>
          </li>
        ))}
      </ul>

      <footer className="rdr-thread-footer">
        {replying ? (
          <DraftComposer
            initialValue=""
            autosaveOnBlur={false}
            saveLabel="Reply"
            placeholder="Reply… (⌘+Enter to save, Esc to cancel)"
            onSave={(body) => {
              onReply?.(thread, body)
              setReplying(false)
            }}
            onCancel={() => setReplying(false)}
          />
        ) : onReply ? (
          <button
            type="button"
            className="rdr-thread-reply"
            onClick={() => setReplying(true)}
          >
            Reply
          </button>
        ) : null}
      </footer>
    </div>
  )
}

function DraftBubble({ draft, onRemove, onEdit, onScrollToAnchor }) {
  const [editing, setEditing] = useState(false)
  const { relative, absolute } = formatRelative(draft.updated_at || draft.inserted_at)

  if (editing) {
    return (
      <div className="rdr-draft" data-draft-id={draft.id}>
        <DraftComposer
          initialValue={draft.body}
          autosaveOnBlur={false}
          saveLabel="Save Draft"
          onSave={(body) => {
            onEdit?.(draft, body)
            setEditing(false)
          }}
          onCancel={() => setEditing(false)}
        />
      </div>
    )
  }

  return (
    <div className="rdr-draft" data-draft-id={draft.id}>
      <header className="rdr-draft-header">
        <button
          type="button"
          className="rdr-thread-anchor-link"
          onClick={onScrollToAnchor}
          title="Jump to source line"
        >
          <Avatar user={draft.author} />
          <span className="rdr-thread-author">
            {draft.author?.username || "you"}
          </span>
          <span className="rdr-draft-tag">draft</span>
          <span className="rdr-anchor-pinpoint">
            {anchorPinpoint(draft.anchor, draft.side)}
          </span>
        </button>
        <div className="rdr-draft-actions">
          {relative ? (
            <time
              className="rdr-draft-time"
              dateTime={absolute}
              title={absolute}
            >
              Saved {relative}
            </time>
          ) : null}
          {onEdit ? (
            <button
              type="button"
              className="rdr-draft-edit"
              onClick={() => setEditing(true)}
            >
              Edit
            </button>
          ) : null}
          {onRemove ? (
            <button
              type="button"
              className="rdr-draft-remove"
              onClick={onRemove}
            >
              Remove
            </button>
          ) : null}
        </div>
      </header>
      <div className="rdr-draft-body">{draft.body}</div>
    </div>
  )
}

function SignInPrompt({ onCancel }) {
  return (
    <div className="rdr-composer">
      <p className="rdr-composer-signin-text">
        Sign in with GitHub to leave a comment.
      </p>
      <div className="rdr-composer-actions">
        <a href="/auth/github" className="rdr-composer-save">
          Sign in with GitHub
        </a>
        <button type="button" className="rdr-composer-cancel" onClick={onCancel}>
          Cancel
        </button>
      </div>
    </div>
  )
}

function DraftComposer({
  initialValue,
  onSave,
  onCancel,
  autosaveOnBlur = true,
  saveLabel = "Save Draft",
  placeholder = "Leave a comment… (⌘+Enter to save, Esc to cancel)",
}) {
  const [value, setValue] = useState(initialValue || "")
  const textareaRef = useRef(null)

  useEffect(() => {
    textareaRef.current?.focus()
  }, [])

  function submit() {
    const trimmed = value.trim()
    if (!trimmed) {
      onCancel?.()
      return
    }
    onSave(trimmed)
  }

  function onKeyDown(e) {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault()
      submit()
    } else if (e.key === "Escape") {
      e.preventDefault()
      onCancel?.()
    }
  }

  return (
    <div className="rdr-composer">
      <textarea
        ref={textareaRef}
        className="rdr-composer-textarea"
        value={value}
        onChange={(e) => setValue(e.target.value)}
        onBlur={autosaveOnBlur ? submit : undefined}
        onKeyDown={onKeyDown}
        placeholder={placeholder}
        rows={3}
      />
      <div className="rdr-composer-actions">
        <button type="button" className="rdr-composer-save" onClick={submit}>
          {saveLabel}
        </button>
        <button type="button" className="rdr-composer-cancel" onClick={onCancel}>
          Cancel
        </button>
      </div>
    </div>
  )
}

function DiffRow({
  row,
  index,
  fileId,
  filePath,
  side,
  signedIn,
  threads,
  drafts,
  composerOpenAt,
  onOpenComposer,
  onCloseComposer,
  onSaveDraft,
  onDeleteDraft,
  onReply,
  onEdit,
  highlightedTokens,
}) {
  if (row.type === "hunk") {
    return (
      <div className="rdr-row rdr-row-hunk">
        <span className="rdr-line-number" />
        <span className="rdr-line-number" />
        <span className="rdr-line-content">{row.content}</span>
      </div>
    )
  }

  const anchorRanges = computeAnchorRanges(row.content, [...threads, ...drafts])
  const hasAttachments = threads.length > 0 || drafts.length > 0
  const lineClass = `rdr-row rdr-row-${row.type}${hasAttachments ? " rdr-row-anchored" : ""}`
  const composerOpen = composerOpenAt === index
  const activeSide =
    row.type === "del" ? "old" : row.type === "add" ? "new" : side
  const oldInteractive = row.oldNumber && activeSide === "old"
  const newInteractive = row.newNumber && activeSide === "new"
  const rowDomId = fileId ? `file-${fileId}-row-${index}` : undefined

  const scrollToThisRow = () => {
    if (fileId) flashRow(fileId, index)
  }

  return (
    <>
      <div className={lineClass} id={rowDomId}>
        <LineNumber
          number={row.oldNumber}
          side="old"
          interactive={oldInteractive}
          onClick={() => onOpenComposer(index, "old")}
        />
        <LineNumber
          number={row.newNumber}
          side="new"
          interactive={newInteractive}
          onClick={() => onOpenComposer(index, "new")}
        />
        <pre className="rdr-line-content" translate="no" data-row-index={index}>
          <HighlightedCode
            content={row.content}
            tokens={highlightedTokens}
            anchorRanges={anchorRanges}
          />
        </pre>
      </div>

      {threads.map((t) => (
        <div className="rdr-row rdr-row-annotation" key={`thread-${t.id}`}>
          <span className="rdr-line-number" />
          <span className="rdr-line-number" />
          <div className="rdr-annotation">
            <ThreadBubble
              thread={t}
              onScrollToAnchor={scrollToThisRow}
              onReply={onReply}
            />
          </div>
        </div>
      ))}

      {drafts.map((d) => (
        <div className="rdr-row rdr-row-annotation" key={`draft-${d.id}`}>
          <span className="rdr-line-number" />
          <span className="rdr-line-number" />
          <div className="rdr-annotation">
            <DraftBubble
              draft={d}
              onRemove={() => onDeleteDraft(d.id)}
              onEdit={onEdit}
              onScrollToAnchor={scrollToThisRow}
            />
          </div>
        </div>
      ))}

      {composerOpen ? (
        <div className="rdr-row rdr-row-annotation">
          <span className="rdr-line-number" />
          <span className="rdr-line-number" />
          <div className="rdr-annotation">
            {signedIn ? (
              <DraftComposer
                onSave={(body) => onSaveDraft(index, body, activeSide)}
                onCancel={onCloseComposer}
              />
            ) : (
              <SignInPrompt onCancel={onCloseComposer} />
            )}
          </div>
        </div>
      ) : null}
    </>
  )
}

function DiffFile({
  fileId,
  filePath,
  fileStatus,
  side,
  signedIn,
  rawDiff,
  threads,
  drafts,
  onSaveDraft,
  onDeleteDraft,
}) {
  const parsed = useMemo(() => parseUnifiedDiff(rawDiff), [rawDiff])
  const [highlightedLines, setHighlightedLines] = useState(null)
  const [composerOpenAt, setComposerOpenAt] = useState(null)
  const [pendingSelection, setPendingSelection] = useState(null)
  const [selectionPill, setSelectionPill] = useState(null)
  const fileBodyRef = useRef(null)

  useEffect(() => {
    const lang = languageForFile(filePath)
    if (!lang || parsed.rows.length === 0) {
      setHighlightedLines(null)
      return
    }

    let cancelled = false
    const code = parsed.rows.map((row) => (row.type === "hunk" ? "" : row.content)).join("\n")

    codeToTokens(code, { lang, theme: SHIKI_THEME })
      .then(({ tokens }) => {
        if (!cancelled) setHighlightedLines(tokens)
      })
      .catch(() => {
        if (!cancelled) setHighlightedLines(null)
      })

    return () => {
      cancelled = true
    }
  }, [filePath, parsed.rows])

  useEffect(() => {
    function onSelectionChange() {
      if (!fileBodyRef.current) return
      const sel = window.getSelection?.()
      if (!sel || sel.isCollapsed || sel.rangeCount === 0) {
        setSelectionPill(null)
        return
      }
      const range = sel.getRangeAt(0)
      const root = fileBodyRef.current
      if (!root.contains(range.startContainer) || !root.contains(range.endContainer)) {
        setSelectionPill(null)
        return
      }
      const startLine = range.startContainer.parentElement?.closest("[data-row-index]")
      const endLine = range.endContainer.parentElement?.closest("[data-row-index]")
      if (!startLine || startLine !== endLine) {
        // Multi-line / cross-row selection: ignore for token anchoring.
        setSelectionPill(null)
        return
      }
      const rowIndex = Number(startLine.dataset.rowIndex)
      const selectionText = sel.toString()
      if (!selectionText.trim()) {
        setSelectionPill(null)
        return
      }
      const lineText = startLine.textContent || ""
      // Compute the start offset of the selection within the line's textContent.
      const lineRange = document.createRange()
      lineRange.selectNodeContents(startLine)
      lineRange.setEnd(range.startContainer, range.startOffset)
      const selectionStart = lineRange.toString().length

      const rect = range.getBoundingClientRect()
      const rootRect = root.getBoundingClientRect()
      setSelectionPill({
        top: rect.top - rootRect.top + root.scrollTop - 30,
        left: rect.left - rootRect.left + root.scrollLeft,
      })
      setPendingSelection({
        rowIndex,
        selectionText,
        selectionStart,
        lineText,
      })
    }

    document.addEventListener("selectionchange", onSelectionChange)
    return () => document.removeEventListener("selectionchange", onSelectionChange)
  }, [])

  function openComposerForSelection() {
    if (!pendingSelection) return
    setComposerOpenAt(pendingSelection.rowIndex)
    setSelectionPill(null)
  }

  // Index threads/drafts by row index so we can render them inline. We match
  // by `line_number_hint` + `side`; a real anchoring pass happens server-side
  // later and would refine this.
  const threadsByRow = useMemo(
    () => groupAnchorsByRow(parsed.rows, threads),
    [parsed, threads]
  )
  const draftsByRow = useMemo(
    () => groupAnchorsByRow(parsed.rows, drafts),
    [parsed, drafts]
  )

  function handleSave(rowIndex, body, anchorSide = side) {
    const row = parsed.rows[rowIndex]
    if (!row || row.type === "hunk") return
    const ctx = buildContextSnapshot(parsed.rows, rowIndex)
    const lineNumberHint = anchorSide === "old" ? row.oldNumber : row.newNumber

    const tokenSel =
      pendingSelection && pendingSelection.rowIndex === rowIndex ? pendingSelection : null

    const anchor = tokenSel
      ? {
          granularity: "token_range",
          line_text: row.content,
          line_number_hint: lineNumberHint,
          context_before: ctx.before,
          context_after: ctx.after,
          selection_text: tokenSel.selectionText,
          selection_offset: tokenSel.selectionStart,
        }
      : {
          granularity: "line",
          line_text: row.content,
          context_before: ctx.before,
          context_after: ctx.after,
          line_number_hint: lineNumberHint,
        }

    onSaveDraft(
      {
        file_path: filePath,
        side: anchorSide,
        line_text: row.content,
        thread_anchor: anchor,
      },
      body
    )
    setComposerOpenAt(null)
    setPendingSelection(null)
  }

  function handleReply(thread, body) {
    if (!signedIn) return
    onSaveDraft(
      {
        file_path: thread.file_path,
        side: thread.side,
        thread_id: thread.id,
        thread_anchor: thread.anchor,
      },
      body
    )
  }

  function handleEdit(draft, body) {
    if (!signedIn) return
    onSaveDraft(
      {
        file_path: draft.file_path,
        side: draft.side,
        thread_id: draft.thread_id,
        thread_anchor: draft.anchor,
      },
      body
    )
  }

  return (
    <div className="rdr-file">
      <div className="rdr-file-body" ref={fileBodyRef} style={{ position: "relative" }}>
        {parsed.rows.length === 0 ? (
          <p className="rdr-empty">No hunks in this file.</p>
        ) : (
          parsed.rows.map((row, index) => (
            <DiffRow
              key={index}
              row={row}
              index={index}
              fileId={fileId}
              filePath={filePath}
              side={side}
              signedIn={signedIn}
              threads={threadsByRow[index] || []}
              drafts={draftsByRow[index] || []}
              composerOpenAt={composerOpenAt}
              onOpenComposer={(i) => {
                setPendingSelection(null)
                setSelectionPill(null)
                setComposerOpenAt(i)
              }}
              onCloseComposer={() => setComposerOpenAt(null)}
              onSaveDraft={handleSave}
              onDeleteDraft={onDeleteDraft}
              onReply={signedIn ? handleReply : null}
              onEdit={signedIn ? handleEdit : null}
              highlightedTokens={highlightedLines?.[index]}
            />
          ))
        )}
        {selectionPill ? (
          <button
            type="button"
            className="rdr-selection-pill"
            style={{ top: selectionPill.top, left: selectionPill.left }}
            // mousedown fires before selectionchange clears, so use it to
            // preserve the selection up to the click.
            onMouseDown={(e) => {
              e.preventDefault()
              openComposerForSelection()
            }}
          >
            Comment on selection
          </button>
        ) : null}
      </div>
    </div>
  )
}

function findRowIndexFor(rows, side, lineNumberHint) {
  let idx = rows.findIndex((r) => {
    if (r.type === "hunk") return false
    const num = side === "old" ? r.oldNumber : r.newNumber
    return num === lineNumberHint
  })
  if (idx < 0) idx = rows.findIndex((r) => r.type !== "hunk")
  return idx
}

function groupAnchorsByRow(rows, items) {
  // items: [{ id, anchor: { line_number_hint, ... }, side, ... }]
  // For each item, find the row whose new/old number matches the hint on the
  // matching side. If we can't find one, drop it on the first hunk row so it
  // still renders (visible but obviously misanchored).
  const out = {}
  for (const item of items) {
    const idx = findRowIndexFor(rows, item.side, item.anchor?.line_number_hint)
    if (idx < 0) continue
    out[idx] = out[idx] || []
    out[idx].push(item)
  }
  return out
}

// ----------------------------------------------------------------------------
// Container component that owns the per-file state mounted by the LiveView
// hook. It receives initial props on mount and then `setState` calls via the
// imperative handle (`updateProps`) wired up in `mounted`/`handleEvent`.
// ----------------------------------------------------------------------------

function FileIsland({ initialProps, onSaveDraft, onDeleteDraft, registerUpdater }) {
  const [props, setProps] = useState(initialProps)

  useEffect(() => {
    registerUpdater((next) => setProps((prev) => ({ ...prev, ...next })))
  }, [registerUpdater])

  return (
    <DiffFile
      fileId={props.fileId}
      filePath={props.filePath}
      fileStatus={props.fileStatus}
      side={props.side}
      signedIn={props.signedIn}
      rawDiff={props.rawDiff}
      threads={props.threads || []}
      drafts={props.drafts || []}
      onSaveDraft={onSaveDraft}
      onDeleteDraft={onDeleteDraft}
    />
  )
}

// ----------------------------------------------------------------------------
// LiveView hook
// ----------------------------------------------------------------------------

function safeParseJson(text, fallback) {
  if (!text) return fallback
  try {
    return JSON.parse(text)
  } catch (_e) {
    return fallback
  }
}

const DiffRenderer = {
  mounted() {
    const ds = this.el.dataset
    const initialProps = {
      fileId: ds.fileId,
      filePath: ds.filePath,
      fileStatus: ds.fileStatus,
      side: ds.side || "new",
      signedIn: ds.signedIn === "true",
      patchsetNumber: ds.patchsetNumber,
      rawDiff: ds.rawDiff || "",
      threads: safeParseJson(ds.threads, []),
      drafts: safeParseJson(ds.drafts, []),
    }

    let updater = () => {}
    const registerUpdater = (fn) => {
      updater = fn
    }

    const onSaveDraft = (payload, body) => {
      this.pushEvent("save_draft", { ...payload, body })
    }

    const onDeleteDraft = (commentId) => {
      this.pushEvent("delete_draft", { comment_id: commentId })
    }

    const root = createRoot(this.el)
    root.render(
      <FileIsland
        initialProps={initialProps}
        onSaveDraft={onSaveDraft}
        onDeleteDraft={onDeleteDraft}
        registerUpdater={registerUpdater}
      />
    )

    this._root = root
    this._update = (next) => updater(next)
    this._fileId = initialProps.fileId
    this._parsedRows = parseUnifiedDiff(initialProps.rawDiff).rows

    // Server pushes per-file updates as `thread_published:<file_path>` events
    // (file-path-scoped so multiple file islands don't all re-render on every
    // publish across the review).
    this._unsubscribeThreadPublished = this.handleEvent(
      `threads_updated:${initialProps.filePath}`,
      ({ threads, drafts }) => {
        this._update({
          threads: threads || [],
          drafts: drafts || [],
        })
      }
    )

    // The sidebar dispatches reviews:scroll-to-anchor on click. Each island
    // listens; only the one whose data-file-id matches acts.
    this._onScrollDispatch = (event) => {
      const detail = event.detail || {}
      if (String(detail.file_id) !== String(this._fileId)) return
      const idx = findRowIndexFor(this._parsedRows, detail.side, detail.line_number_hint)
      if (idx < 0) return
      flashRow(this._fileId, idx)
    }
    document.addEventListener("reviews:scroll-to-anchor", this._onScrollDispatch)
  },

  updated() {
    // We own the DOM (phx-update="ignore"), so updates to the wrapper element
    // don't unmount us. We could re-read data-* attributes here to pick up
    // changes, but the server-pushed `threads_updated:<file>` event is the
    // canonical refresh path.
  },

  destroyed() {
    if (this._onScrollDispatch) {
      document.removeEventListener("reviews:scroll-to-anchor", this._onScrollDispatch)
      this._onScrollDispatch = null
    }
    this._root?.unmount()
    this._root = null
  },
}

export default DiffRenderer
