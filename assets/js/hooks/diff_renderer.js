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

function HighlightedCode({ content, tokens }) {
  if (!tokens || tokens.length === 0) return content

  return tokens.map((token, i) => (
    <span key={i} style={tokenStyle(token)}>
      {token.content}
    </span>
  ))
}

// ----------------------------------------------------------------------------
// React components
// ----------------------------------------------------------------------------

function ThreadBubble({ thread }) {
  return (
    <div className="rdr-thread" data-thread-id={thread.id}>
      <div className="rdr-thread-header">
        <span className="rdr-thread-author">{thread.author?.username || "reviewer"}</span>
      </div>
      <ul className="rdr-thread-comments">
        {(thread.comments || []).map((c) => (
          <li key={c.id} className="rdr-thread-comment">
            <span className="rdr-thread-comment-author">{c.author?.username || "reviewer"}</span>
            <span className="rdr-thread-comment-body">{c.body}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}

function DraftBubble({ draft, onRemove }) {
  return (
    <div className="rdr-draft" data-draft-id={draft.id}>
      <div className="rdr-draft-header">
        <span className="rdr-draft-tag">draft</span>
        {onRemove ? (
          <button type="button" className="rdr-draft-remove" onClick={onRemove}>
            Remove
          </button>
        ) : null}
      </div>
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

function DraftComposer({ initialValue, onSave, onCancel }) {
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
        onBlur={submit}
        onKeyDown={onKeyDown}
        placeholder="Leave a comment… (⌘+Enter to save, Esc to cancel)"
        rows={3}
      />
      <div className="rdr-composer-actions">
        <button type="button" className="rdr-composer-save" onClick={submit}>
          Save Draft
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

  const lineClass = `rdr-row rdr-row-${row.type}`
  const composerOpen = composerOpenAt === index

  return (
    <>
      <div className={lineClass}>
        <button
          type="button"
          className="rdr-line-number rdr-line-number-clickable"
          aria-label="Add comment"
          onClick={() => onOpenComposer(index)}
        >
          {row.oldNumber ?? ""}
        </button>
        <button
          type="button"
          className="rdr-line-number rdr-line-number-clickable"
          aria-label="Add comment"
          onClick={() => onOpenComposer(index)}
        >
          {row.newNumber ?? ""}
        </button>
        <pre className="rdr-line-content" translate="no" data-row-index={index}>
          <HighlightedCode content={row.content} tokens={highlightedTokens} />
        </pre>
      </div>

      {threads.map((t) => (
        <div className="rdr-row rdr-row-annotation" key={`thread-${t.id}`}>
          <span className="rdr-line-number" />
          <span className="rdr-line-number" />
          <div className="rdr-annotation">
            <ThreadBubble thread={t} />
          </div>
        </div>
      ))}

      {drafts.map((d) => (
        <div className="rdr-row rdr-row-annotation" key={`draft-${d.id}`}>
          <span className="rdr-line-number" />
          <span className="rdr-line-number" />
          <div className="rdr-annotation">
            <DraftBubble draft={d} onRemove={() => onDeleteDraft(d.id)} />
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
                onSave={(body) => onSaveDraft(index, body)}
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

function DiffFile({ filePath, fileStatus, side, signedIn, rawDiff, threads, drafts, onSaveDraft, onDeleteDraft }) {
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

  function handleSave(rowIndex, body) {
    const row = parsed.rows[rowIndex]
    if (!row || row.type === "hunk") return
    const ctx = buildContextSnapshot(parsed.rows, rowIndex)
    const lineNumberHint = side === "old" ? row.oldNumber : row.newNumber

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
        side,
        line_text: row.content,
        thread_anchor: anchor,
      },
      body
    )
    setComposerOpenAt(null)
    setPendingSelection(null)
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

function groupAnchorsByRow(rows, items) {
  // items: [{ id, anchor: { line_number_hint, ... }, side, ... }]
  // For each item, find the row whose new/old number matches the hint on the
  // matching side. If we can't find one, drop it on the first hunk row so it
  // still renders (visible but obviously misanchored).
  const out = {}
  for (const item of items) {
    const side = item.side
    const hint = item.anchor?.line_number_hint
    let idx = rows.findIndex((r) => {
      if (r.type === "hunk") return false
      const num = side === "old" ? r.oldNumber : r.newNumber
      return num === hint
    })
    if (idx < 0) idx = rows.findIndex((r) => r.type !== "hunk")
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
  },

  updated() {
    // We own the DOM (phx-update="ignore"), so updates to the wrapper element
    // don't unmount us. We could re-read data-* attributes here to pick up
    // changes, but the server-pushed `threads_updated:<file>` event is the
    // canonical refresh path.
  },

  destroyed() {
    this._root?.unmount()
    this._root = null
  },
}

export default DiffRenderer
