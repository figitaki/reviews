// DiffRenderer — Phoenix LiveView hook that mounts a React island per file.
//
// The diff body is rendered by `<PatchDiff>` from `@pierre/diffs/react`.
// We wrap it with our own thread/draft/composer UX via:
//
//   * `lineAnnotations`     — fed from server-pushed thread + draft payloads
//                             via `threadsAndDraftsToAnnotations`, grouped by
//                             (side, lineNumber).
//   * `renderAnnotation`    — returns a React node rendered into PatchDiff's
//                             shadow DOM. Bubbles inline their own styles
//                             because our `.rdr-*` CSS can't reach in there.
//   * `onLineNumberClick`   — opens a draft composer attached as a one-off
//                             annotation at that line.
//
// LiveView contract is unchanged from before the spike:
//   * Each per-file `<div phx-hook="DiffRenderer" phx-update="ignore">` carries
//     `data-raw-diff`, `data-threads`, `data-drafts`, etc.
//   * We mount a React root inside `this.el` and stream updates via the
//     `threads_updated:<file_path>` push event.

import React, { useState, useEffect, useMemo } from "react"
import { createRoot } from "react-dom/client"
import { PatchDiff } from "@pierre/diffs/react"

import { Thread, Draft, SaveDraftPayload } from "../schemas.js"
import {
  threadsAndDraftsToAnnotations,
  annotationSideToSide,
} from "../lib/translate.js"

// ----------------------------------------------------------------------------
// Inline style maps for bubbles.
//
// The diff body is rendered into shadow DOM, so global `.rdr-*` CSS rules in
// `assets/css/app.css` cannot reach `renderAnnotation` output. Bubbles ship
// their styles inline. The CSS-variable colors fall through to the library's
// theme variables, which keeps everything cohesive with the diff body.
// ----------------------------------------------------------------------------

const colors = {
  panel: "var(--ds-panel, #050505)",
  raised: "var(--ds-panel-raised, #0b0b0c)",
  text: "var(--ds-text, #f5f5f5)",
  muted: "var(--ds-muted, #a3a3a3)",
  faint: "var(--ds-faint, #707073)",
  line: "var(--ds-line, #242426)",
  lineStrong: "var(--ds-line-strong, #3a3a3d)",
  hover: "var(--ds-hover, #111113)",
  warn: "var(--ds-warn, #ffd166)",
  add: "var(--ds-add, #25d0a0)",
}

const fontStack =
  'system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
const monoStack =
  "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace"

const bubbleBaseStyle = {
  border: `1px solid ${colors.line}`,
  borderRadius: 8,
  background: colors.panel,
  color: colors.text,
  fontFamily: fontStack,
  fontSize: 13,
  padding: "10px 12px",
  marginBottom: 8,
}

const draftBubbleStyle = {
  ...bubbleBaseStyle,
  borderStyle: "dashed",
}

const composerStyle = {
  ...bubbleBaseStyle,
  padding: 10,
}

const buttonStyle = {
  display: "inline-flex",
  alignItems: "center",
  justifyContent: "center",
  minHeight: 30,
  cursor: "pointer",
  border: `1px solid ${colors.lineStrong}`,
  borderRadius: 6,
  background: "transparent",
  color: colors.text,
  font: "inherit",
  fontFamily: fontStack,
  fontSize: 12,
  padding: "0 10px",
  textDecoration: "none",
}

const primaryButtonStyle = {
  ...buttonStyle,
  background: colors.text,
  borderColor: colors.text,
  color: "#050505",
}

const textareaStyle = {
  minHeight: 72,
  width: "100%",
  resize: "vertical",
  border: `1px solid ${colors.lineStrong}`,
  borderRadius: 6,
  background: "#000",
  color: "inherit",
  font: "inherit",
  fontFamily: fontStack,
  padding: "8px 10px",
  boxSizing: "border-box",
}

const anchorLinkStyle = {
  display: "inline-flex",
  alignItems: "center",
  gap: 6,
  background: "transparent",
  border: "none",
  padding: 0,
  color: "inherit",
  font: "inherit",
  cursor: "pointer",
}

const anchorPinpointStyle = {
  color: colors.muted,
  fontSize: 11,
  fontFamily: monoStack,
}

const statusPillBaseStyle = {
  marginLeft: 6,
  padding: "1px 6px",
  borderRadius: 999,
  fontSize: 10,
  fontWeight: 700,
  textTransform: "uppercase",
  letterSpacing: "0.04em",
  border: `1px solid ${colors.lineStrong}`,
  background: colors.raised,
  color: colors.muted,
}

const statusPillStyle = {
  open: {
    ...statusPillBaseStyle,
    color: colors.warn,
    borderColor: `color-mix(in srgb, ${colors.warn} 50%, transparent)`,
  },
  resolved: {
    ...statusPillBaseStyle,
    color: colors.add,
    borderColor: `color-mix(in srgb, ${colors.add} 50%, transparent)`,
  },
  outdated: { ...statusPillBaseStyle, color: colors.faint },
}

const tokenQuoteStyle = {
  fontFamily: monoStack,
  fontSize: 11,
  padding: "1px 4px",
  borderRadius: 4,
  background: `color-mix(in srgb, ${colors.warn} 14%, transparent)`,
  color: colors.text,
  border: `1px solid color-mix(in srgb, ${colors.warn} 40%, transparent)`,
  whiteSpace: "pre",
}

const avatarStyle = (size) => ({
  display: "inline-block",
  width: size,
  height: size,
  borderRadius: "50%",
  verticalAlign: "middle",
  background: colors.raised,
  flex: "0 0 auto",
})

const avatarFallbackStyle = (size) => ({
  ...avatarStyle(size),
  display: "inline-flex",
  alignItems: "center",
  justifyContent: "center",
  fontSize: 11,
  fontWeight: 700,
  color: colors.muted,
  border: `1px solid ${colors.line}`,
})

const threadCommentsStyle = { listStyle: "none", margin: 0, padding: 0 }
const threadRunStyle = { marginTop: 8 }
const threadRunHeaderStyle = {
  display: "flex",
  alignItems: "center",
  gap: 6,
  marginTop: 4,
  fontWeight: 600,
}
const threadRunCommentsStyle = {
  margin: "4px 0 0 0",
  padding: "0 0 0 26px",
  listStyle: "none",
}
const threadCommentStyle = { padding: "2px 0" }
const threadCommentBodyStyle = { whiteSpace: "pre-wrap" }
const threadCommentTimeStyle = {
  display: "inline-block",
  marginLeft: 6,
  color: colors.faint,
  fontSize: 11,
}
const threadFooterStyle = {
  marginTop: 8,
  borderTop: `1px solid ${colors.line}`,
  paddingTop: 8,
}

const draftHeaderStyle = {
  display: "flex",
  alignItems: "center",
  justifyContent: "space-between",
  gap: 8,
  marginBottom: 6,
  fontWeight: 600,
}

const draftActionsStyle = {
  display: "inline-flex",
  alignItems: "center",
  gap: 6,
}

const draftTagStyle = {
  color: colors.muted,
  fontSize: 11,
  fontWeight: 600,
  textTransform: "uppercase",
}

const draftBodyStyle = { whiteSpace: "pre-wrap" }

const composerActionsStyle = {
  display: "flex",
  gap: 8,
  marginTop: 8,
}

const signInTextStyle = {
  margin: "0 0 8px 0",
  color: colors.muted,
  fontFamily: fontStack,
  fontSize: 13,
}

// ----------------------------------------------------------------------------
// Bubble helpers — small pure functions reused across thread + draft bubbles.
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

// ----------------------------------------------------------------------------
// React components — all styles inline because we render into shadow DOM.
// ----------------------------------------------------------------------------

function Avatar({ user, size = 20 }) {
  if (!user) return null
  if (user.avatar_url) {
    return (
      <img
        src={user.avatar_url}
        alt=""
        width={size}
        height={size}
        loading="lazy"
        decoding="async"
        style={avatarStyle(size)}
      />
    )
  }
  const initial = (user.username || "?").slice(0, 1).toUpperCase()
  return (
    <span style={avatarFallbackStyle(size)} aria-hidden="true">
      {initial}
    </span>
  )
}

function BubbleAnchorLink({ anchor, side, status, onClick, children }) {
  return (
    <button
      type="button"
      style={anchorLinkStyle}
      onClick={onClick}
      title="Jump to source line"
    >
      {children}
      <span style={anchorPinpointStyle}>{anchorPinpoint(anchor, side)}</span>
      {status ? (
        <span style={statusPillStyle[status] || statusPillBaseStyle}>
          {status}
        </span>
      ) : null}
    </button>
  )
}

function ThreadBubble({ thread, onReply }) {
  const [replying, setReplying] = useState(false)
  const runs = useMemo(
    () => groupCommentsByAuthor(thread.comments),
    [thread.comments]
  )

  return (
    <div
      style={bubbleBaseStyle}
      data-thread-id={thread.id}
      role="group"
      aria-label={`Thread by ${thread.author?.username || "reviewer"}`}
    >
      <header
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          flexWrap: "wrap",
        }}
      >
        <BubbleAnchorLink
          anchor={thread.anchor}
          side={thread.side}
          status={thread.status}
        />
        {thread.anchor?.granularity === "token_range" &&
        thread.anchor.selection_text ? (
          <code style={tokenQuoteStyle}>{thread.anchor.selection_text}</code>
        ) : null}
      </header>

      <ul style={threadCommentsStyle}>
        {runs.map((run, ri) => (
          <li key={ri} style={threadRunStyle}>
            <header style={threadRunHeaderStyle}>
              <Avatar user={run.author} />
              <span>{run.author?.username || "reviewer"}</span>
            </header>
            <ul style={threadRunCommentsStyle}>
              {run.comments.map((c) => {
                const { relative, absolute } = formatRelative(c.inserted_at)
                return (
                  <li key={c.id} style={threadCommentStyle}>
                    <div style={threadCommentBodyStyle}>{c.body}</div>
                    {relative ? (
                      <time
                        style={threadCommentTimeStyle}
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

      <footer style={threadFooterStyle}>
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
            style={buttonStyle}
            onClick={() => setReplying(true)}
          >
            Reply
          </button>
        ) : null}
      </footer>
    </div>
  )
}

function DraftBubble({ draft, onRemove, onEdit }) {
  const [editing, setEditing] = useState(false)
  const { relative, absolute } = formatRelative(
    draft.updated_at || draft.inserted_at
  )

  if (editing) {
    return (
      <div style={draftBubbleStyle} data-draft-id={draft.id}>
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
    <div style={draftBubbleStyle} data-draft-id={draft.id}>
      <header style={draftHeaderStyle}>
        <BubbleAnchorLink anchor={draft.anchor} side={draft.side}>
          <Avatar user={draft.author} />
          <span>{draft.author?.username || "you"}</span>
          <span style={draftTagStyle}>draft</span>
        </BubbleAnchorLink>
        <div style={draftActionsStyle}>
          {relative ? (
            <time
              style={threadCommentTimeStyle}
              dateTime={absolute}
              title={absolute}
            >
              Saved {relative}
            </time>
          ) : null}
          {onEdit ? (
            <button
              type="button"
              style={buttonStyle}
              onClick={() => setEditing(true)}
            >
              Edit
            </button>
          ) : null}
          {onRemove ? (
            <button type="button" style={buttonStyle} onClick={onRemove}>
              Remove
            </button>
          ) : null}
        </div>
      </header>
      {draft.anchor?.granularity === "token_range" &&
      draft.anchor.selection_text ? (
        <div style={{ marginBottom: 6 }}>
          <code style={tokenQuoteStyle}>{draft.anchor.selection_text}</code>
        </div>
      ) : null}
      <div style={draftBodyStyle}>{draft.body}</div>
    </div>
  )
}

function SignInPrompt({ onCancel }) {
  return (
    <div style={composerStyle}>
      <p style={signInTextStyle}>Sign in with GitHub to leave a comment.</p>
      <div style={composerActionsStyle}>
        <a href="/auth/github" style={primaryButtonStyle}>
          Sign in with GitHub
        </a>
        <button type="button" style={buttonStyle} onClick={onCancel}>
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
  const textareaRef = React.useRef(null)

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
    <div style={composerStyle}>
      <textarea
        ref={textareaRef}
        style={textareaStyle}
        value={value}
        onChange={(e) => setValue(e.target.value)}
        onBlur={autosaveOnBlur ? submit : undefined}
        onKeyDown={onKeyDown}
        placeholder={placeholder}
        rows={3}
      />
      <div style={composerActionsStyle}>
        <button type="button" style={primaryButtonStyle} onClick={submit}>
          {saveLabel}
        </button>
        <button type="button" style={buttonStyle} onClick={onCancel}>
          Cancel
        </button>
      </div>
    </div>
  )
}

// ----------------------------------------------------------------------------
// The container component owned by the LiveView hook. Holds threads/drafts
// state (refreshed via `threads_updated:<file>` push events), composer state,
// and renders <PatchDiff> with the wired lineAnnotations + renderAnnotation.
// ----------------------------------------------------------------------------

function FileIsland({
  filePath,
  rawDiff,
  signedIn,
  initial,
  registerUpdater,
  onSaveDraft,
  onDeleteDraft,
}) {
  const [threads, setThreads] = useState(initial.threads)
  const [drafts, setDrafts] = useState(initial.drafts)
  // composerAt: null | { side: 'additions'|'deletions', lineNumber, lineText, signInOnly? }
  const [composerAt, setComposerAt] = useState(null)

  useEffect(() => {
    registerUpdater((next) => {
      if (next.threads) setThreads(next.threads)
      if (next.drafts) setDrafts(next.drafts)
    })
  }, [registerUpdater])

  const annotations = useMemo(
    () => threadsAndDraftsToAnnotations(threads, drafts),
    [threads, drafts]
  )

  // Merge in a one-off composer annotation, if open.
  const lineAnnotations = useMemo(() => {
    const real = annotations.map((a) => ({ ...a, metadata: { kind: "real", ...a.metadata } }))
    if (!composerAt) return real
    // If a real annotation already exists at (side, lineNumber) we still add a
    // separate composer entry — PatchDiff supports multiple annotations per
    // (side, lineNumber); they render stacked.
    return [
      ...real,
      {
        side: composerAt.side,
        lineNumber: composerAt.lineNumber,
        metadata: {
          kind: "composer",
          signInOnly: composerAt.signInOnly === true,
          lineText: composerAt.lineText || "",
        },
      },
    ]
  }, [annotations, composerAt])

  function handleSaveNewDraft(body) {
    if (!composerAt) return
    const lineText = composerAt.lineText || ""
    const side = annotationSideToSide(composerAt.side)
    const anchor = {
      granularity: "line",
      line_text: lineText,
      line_number_hint: composerAt.lineNumber,
      context_before: [],
      context_after: [],
    }
    onSaveDraft({
      file_path: filePath,
      side,
      body,
      thread_anchor: anchor,
      line_text: lineText,
    })
    setComposerAt(null)
  }

  function handleReply(thread, body) {
    if (!signedIn) return
    onSaveDraft({
      file_path: thread.file_path,
      side: thread.side,
      body,
      thread_id: thread.id,
      thread_anchor: thread.anchor,
    })
  }

  function handleEditDraft(draft, body) {
    if (!signedIn) return
    onSaveDraft({
      file_path: draft.file_path,
      side: draft.side,
      body,
      thread_id: draft.thread_id,
      thread_anchor: draft.anchor,
    })
  }

  function renderAnnotation(annotation) {
    const meta = annotation.metadata || {}

    if (meta.kind === "composer") {
      return meta.signInOnly ? (
        <SignInPrompt onCancel={() => setComposerAt(null)} />
      ) : (
        <DraftComposer
          onSave={handleSaveNewDraft}
          onCancel={() => setComposerAt(null)}
        />
      )
    }

    const threadList = meta.threads || []
    const draftList = meta.drafts || []
    return (
      <div>
        {threadList.map((t) => (
          <ThreadBubble
            key={`thread-${t.id}`}
            thread={t}
            onReply={signedIn ? handleReply : null}
          />
        ))}
        {draftList.map((d) => (
          <DraftBubble
            key={`draft-${d.id}`}
            draft={d}
            onRemove={() => onDeleteDraft(d.id)}
            onEdit={signedIn ? handleEditDraft : null}
          />
        ))}
      </div>
    )
  }

  function handleLineNumberClick(props) {
    // OnDiffLineClickProps: { annotationSide, lineNumber, lineElement, ... }
    const side = props?.annotationSide
    const lineNumber = props?.lineNumber
    if (!side || !lineNumber) return
    const lineText =
      (props?.lineElement && props.lineElement.textContent) || ""
    if (!signedIn) {
      setComposerAt({ side, lineNumber, lineText: "", signInOnly: true })
      return
    }
    setComposerAt({ side, lineNumber, lineText })
  }

  return (
    <PatchDiff
      patch={rawDiff}
      disableWorkerPool
      lineAnnotations={lineAnnotations}
      renderAnnotation={renderAnnotation}
      options={{
        onLineNumberClick: handleLineNumberClick,
      }}
      style={{ width: "100%" }}
    />
  )
}

// ----------------------------------------------------------------------------
// LiveView hook
// ----------------------------------------------------------------------------

function parseInitial(text, schema) {
  // Parse a JSON `data-*` payload through a zod array schema. Wire-format
  // drift fails loudly here. We surface to the console so the renderer at
  // least keeps mounting with an empty list rather than blanking the page.
  try {
    const json = JSON.parse(text || "[]")
    return schema.array().parse(json)
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error("[DiffRenderer] failed to parse payload:", err)
    return []
  }
}

const DiffRenderer = {
  mounted() {
    const ds = this.el.dataset
    const filePath = ds.filePath
    const signedIn = ds.signedIn === "true"
    const rawDiff = ds.rawDiff || ""

    const initialThreads = parseInitial(ds.threads, Thread)
    const initialDrafts = parseInitial(ds.drafts, Draft)

    let updater = () => {}
    const registerUpdater = (fn) => {
      updater = fn
    }

    const onSaveDraft = (payload) => {
      try {
        const parsed = SaveDraftPayload.parse(payload)
        this.pushEvent("save_draft", parsed)
      } catch (err) {
        // eslint-disable-next-line no-console
        console.error("[DiffRenderer] invalid save_draft payload:", err, payload)
      }
    }

    const onDeleteDraft = (commentId) => {
      this.pushEvent("delete_draft", { comment_id: commentId })
    }

    const root = createRoot(this.el)
    root.render(
      <FileIsland
        filePath={filePath}
        rawDiff={rawDiff}
        signedIn={signedIn}
        initial={{ threads: initialThreads, drafts: initialDrafts }}
        registerUpdater={registerUpdater}
        onSaveDraft={onSaveDraft}
        onDeleteDraft={onDeleteDraft}
      />
    )

    this._root = root

    // Server pushes per-file refreshes after a save/delete/publish.
    this.handleEvent(`threads_updated:${filePath}`, (raw) => {
      try {
        const threads = Thread.array().parse(raw?.threads ?? [])
        const drafts = Draft.array().parse(raw?.drafts ?? [])
        updater({ threads, drafts })
      } catch (err) {
        // eslint-disable-next-line no-console
        console.error(
          "[DiffRenderer] invalid threads_updated payload:",
          err,
          raw
        )
      }
    })

    // The "Open Threads" sidebar dispatches reviews:scroll-to-anchor on click.
    // Pre-spike this scrolled into the rendered diff and flashed the row. With
    // <PatchDiff> the row lives inside a shadow DOM the sidebar can't reach
    // via `document.getElementById`, so this is intentionally a no-op for v1
    // and will be revisited once the library exposes a scroll-to-line API.
  },

  updated() {
    // The wrapper `<div>` is phx-update="ignore"; we don't react to LiveView
    // diff updates here. State refreshes flow through `threads_updated:*`.
  },

  destroyed() {
    this._root?.unmount()
    this._root = null
  },
}

export default DiffRenderer
