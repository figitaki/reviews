import { button as baseButton, el } from "./dom.js"

// Pierre owns the diff body theme. Annotation UI is rendered by Reviews through
// `renderAnnotation`, so it uses Reviews design tokens and inline styles that
// can survive inside Pierre's shadow DOM.
const colors = {
  panel: "var(--ds-panel, #050505)",
  raised: "var(--ds-panel-raised, #0b0b0c)",
  text: "var(--ds-text, #f5f5f5)",
  muted: "var(--ds-muted, #a3a3a3)",
  faint: "var(--ds-faint, #707073)",
  line: "var(--ds-line, #242426)",
  lineStrong: "var(--ds-line-strong, #3a3a3d)",
  add: "var(--ds-add, #25d0a0)",
}

const fontStack = "var(--font-sans, system-ui, sans-serif)"
const monoStack = "var(--font-mono, ui-monospace, monospace)"

const bubbleBaseStyle = {
  border: `1px solid ${colors.line}`,
  borderRadius: "8px",
  background: colors.panel,
  color: colors.text,
  fontFamily: fontStack,
  fontSize: "13px",
  padding: "10px 12px",
  marginBottom: "8px",
  boxSizing: "border-box",
}

const composerStyle = { ...bubbleBaseStyle, padding: "12px", marginBottom: "0" }

const buttonStyle = {
  display: "inline-flex",
  alignItems: "center",
  justifyContent: "center",
  gap: "6px",
  minHeight: "30px",
  cursor: "pointer",
  border: "1px solid transparent",
  borderRadius: "6px",
  background: colors.raised,
  color: colors.text,
  font: "inherit",
  fontFamily: fontStack,
  fontSize: "12px",
  padding: "0 12px",
  textDecoration: "none",
}

const primaryButtonStyle = {
  ...buttonStyle,
  background: colors.text,
  borderColor: colors.text,
  color: "var(--ds-bg, #050505)",
}

const textareaStyle = {
  minHeight: "56px",
  width: "100%",
  display: "block",
  resize: "vertical",
  border: "none",
  outline: "none",
  background: "transparent",
  color: "inherit",
  font: "inherit",
  fontFamily: fontStack,
  lineHeight: "1.6",
  padding: "0",
  boxSizing: "border-box",
}

const anchorLinkStyle = {
  display: "inline-flex",
  alignItems: "center",
  gap: "6px",
  background: "transparent",
  border: "none",
  padding: "0",
  color: colors.text,
  font: "inherit",
  fontWeight: "600",
  cursor: "pointer",
}

const anchorPinpointStyle = {
  color: colors.text,
  fontSize: "12px",
  fontFamily: monoStack,
  fontWeight: "600",
}

const statusPillBaseStyle = {
  marginLeft: "6px",
  padding: "1px 6px",
  borderRadius: "999px",
  fontSize: "11px",
  fontWeight: "500",
  border: `1px solid ${colors.lineStrong}`,
  background: colors.raised,
  color: colors.muted,
}

const statusPillStyle = {
  open: statusPillBaseStyle,
  resolved: {
    ...statusPillBaseStyle,
    color: colors.add,
    borderColor: `color-mix(in srgb, ${colors.add} 50%, transparent)`,
  },
  outdated: { ...statusPillBaseStyle, color: colors.faint },
}

const threadRunStyle = { marginTop: "8px" }
const threadRunHeaderStyle = {
  display: "flex",
  alignItems: "center",
  gap: "6px",
  marginTop: "4px",
  fontWeight: "600",
}
const threadRunCommentsStyle = {
  margin: "4px 0 0 0",
  padding: "0 0 0 26px",
  listStyle: "none",
}
const threadCommentStyle = {
  display: "flex",
  alignItems: "baseline",
  flexWrap: "wrap",
  gap: "4px 12px",
  padding: "4px 0",
}
const threadCommentBodyStyle = {
  flex: "1 1 180px",
  minWidth: "0",
  whiteSpace: "pre-wrap",
  overflowWrap: "anywhere",
}
const threadCommentTimeStyle = {
  flex: "0 0 auto",
  color: colors.faint,
  fontSize: "11px",
}
const threadFooterStyle = {
  marginTop: "8px",
  borderTop: `1px solid ${colors.line}`,
  paddingTop: "8px",
}
const composerActionsStyle = {
  display: "flex",
  flexWrap: "wrap",
  gap: "8px",
  alignItems: "center",
}

function button(label, onClick, attrs = {}) {
  return baseButton(label, onClick, {
    ...attrs,
    style: buttonStyle,
    primaryStyle: primaryButtonStyle,
  })
}

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

export function anchorPinpoint(anchor, side) {
  if (!anchor) return null
  const line = anchor.line_number_hint
  const sign = side === "old" ? "-" : "+"
  return `${sign}${line}`
}

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

function avatar(user, size = 20) {
  if (!user) return null
  if (user.avatar_url) {
    return el("img", {
      src: user.avatar_url,
      alt: "",
      width: size,
      height: size,
      loading: "lazy",
      decoding: "async",
      style: {
        display: "inline-block",
        width: `${size}px`,
        height: `${size}px`,
        borderRadius: "50%",
        verticalAlign: "middle",
        background: colors.raised,
        flex: "0 0 auto",
      },
    })
  }
  const initial = (user.username || "?").slice(0, 1).toUpperCase()
  return el(
    "span",
    {
      "aria-hidden": "true",
      style: {
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        width: `${size}px`,
        height: `${size}px`,
        borderRadius: "50%",
        fontSize: "11px",
        fontWeight: "700",
        color: colors.muted,
        background: colors.raised,
        border: `1px solid ${colors.line}`,
        flex: "0 0 auto",
      },
    },
    initial
  )
}

function bubbleAnchorLink({ anchor, side, status, commentCount }) {
  const label = commentCount > 1 ? "Comments" : "Comment"
  const text = el("span", {}, [
    `${label} on line `,
    el("span", { style: anchorPinpointStyle }, anchorPinpoint(anchor, side)),
  ])
  const children = [text]
  if (status) {
    const label = { open: "Open", resolved: "Resolved", outdated: "Outdated" }[status] || status
    children.push(el("span", { style: statusPillStyle[status] || statusPillBaseStyle }, label))
  }
  return el(
    "button",
    {
      type: "button",
      style: anchorLinkStyle,
      title: "Jump to source line",
    },
    children
  )
}

export function commentComposer({
  initialValue = "",
  onSave,
  onCancel,
  saveLabel = "Comment",
  placeholder = "Leave a comment…",
  embedded = false,
  onChange,
  autoFocus = true,
}) {
  const textarea = el("textarea", {
    style: textareaStyle,
    rows: 2,
    placeholder,
    "aria-label": saveLabel === "Reply" ? "Reply to thread" : "Comment",
  })
  textarea.value = initialValue

  let submitted = false
  const submit = () => {
    if (submitted) return
    const trimmed = textarea.value.trim()
    if (!trimmed) return
    submitted = true
    saveButton.disabled = true
    onSave?.(trimmed)
  }

  textarea.addEventListener("keydown", (event) => {
    if (event.isComposing) return
    if ((event.metaKey || event.ctrlKey) && event.key === "Enter") {
      event.preventDefault()
      submit()
    } else if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      submitted = true
      onCancel?.()
    }
  })

  const saveButton = button(saveLabel, submit, { primary: true })
  const updateSave = () => {
    saveButton.disabled = submitted || !textarea.value.trim()
    saveButton.style.opacity = saveButton.disabled ? "0.45" : "1"
    saveButton.style.cursor = saveButton.disabled ? "default" : "pointer"
  }
  textarea.addEventListener("input", () => {
    updateSave()
    onChange?.(textarea.value)
  })
  updateSave()

  const shortcut = navigator.platform.includes("Mac") ? "⌘ Enter" : "Ctrl Enter"
  const node = el("div", {
    style: embedded ? { ...composerStyle, border: "none", borderRadius: "0" } : composerStyle,
    role: "group", "aria-label": "Comment composer",
  }, [
    textarea,
    el("div", { style: { ...composerActionsStyle, marginTop: "12px", justifyContent: "space-between" } }, [
      el("span", { style: { color: colors.muted, fontSize: "11px" } }, `${shortcut} to post · Esc to cancel`),
      el("div", { style: composerActionsStyle }, [
        button("Cancel", () => {
          submitted = true
          onCancel?.()
        }),
        saveButton,
      ]),
    ]),
  ])

  // Emphasize the existing edge instead of nesting the browser's focus ring
  // inside another border. Inline styles also work in Pierre's shadow DOM.
  textarea.addEventListener("focus", () => {
    if (embedded) textarea.style.boxShadow = `0 1px 0 ${colors.lineStrong}`
    else node.style.borderColor = "var(--ds-focus, #fff)"
  })
  textarea.addEventListener("blur", () => {
    textarea.style.boxShadow = "none"
    node.style.borderColor = colors.line
  })

  if (autoFocus) window.requestAnimationFrame(() => {
    if (textarea.isConnected) textarea.focus({ preventScroll: true })
  })
  return node
}

export function signInPrompt(onCancel) {
  return el("div", { style: composerStyle }, [
    el(
      "p",
      {
        style: {
          margin: "0 0 8px 0",
          color: colors.muted,
          fontFamily: fontStack,
          fontSize: "13px",
        },
      },
      "Sign in with GitHub to leave a comment."
    ),
    el("div", { style: composerActionsStyle }, [
      el("a", { href: "/auth/github", style: primaryButtonStyle }, "Sign in with GitHub"),
      button("Cancel", onCancel),
    ]),
  ])
}

function commentTime(iso, prefix = "") {
  const { relative, absolute } = formatRelative(iso)
  if (!relative) return null
  return el(
    "time",
    {
      style: threadCommentTimeStyle,
      dateTime: absolute,
      title: absolute,
    },
    `${prefix}${relative}`
  )
}

export function threadBubble({ thread, onReply, onUpdateStatus, ui = {} }) {
  const runs = groupCommentsByAuthor(thread.comments)
  const commentRows = []

  for (const run of runs) {
    const comments = run.comments.map((comment) =>
      el("li", { style: threadCommentStyle }, [
        el("div", { style: threadCommentBodyStyle }, comment.body),
        commentTime(comment.inserted_at),
      ])
    )

    commentRows.push(
      el("li", { style: threadRunStyle }, [
        el("header", { style: threadRunHeaderStyle }, [
          avatar(run.author),
          el("span", {}, run.author?.username || "reviewer"),
        ]),
        el("ul", { style: threadRunCommentsStyle }, comments),
      ])
    )
  }

  let replyButton
  const root = el("div", {
    style: { ...bubbleBaseStyle, padding: "0", overflow: "hidden" },
    role: "group",
    "aria-label": `Thread by ${thread.author?.username || "reviewer"}`,
    dataset: { threadId: thread.id },
  })
  const render = () => {
    const resolved = thread.status === "resolved"
    const expanded = !resolved || ui.expanded
    const where = anchorPinpoint(thread.anchor, thread.side)
    const header = el("header", {
      style: { display: "flex", alignItems: "center", gap: "8px", flexWrap: "wrap", padding: "10px 12px", borderBottom: `1px solid ${colors.line}` },
    }, [bubbleAnchorLink({ anchor: thread.anchor, side: thread.side, status: thread.status, commentCount: thread.comments?.length || 0 })])
    if (onUpdateStatus && ["open", "resolved"].includes(thread.status)) {
      header.append(button(resolved ? "Reopen" : "Resolve", () => {
        ui.expanded = false
        onUpdateStatus(thread, resolved ? "open" : "resolved")
      }, { ariaLabel: `${resolved ? "Reopen" : "Resolve"} thread on line ${where}` }))
    }
    root.replaceChildren(header)
    if (resolved) {
      const history = button(ui.expanded ? "Hide thread" : "View thread", () => {
        ui.expanded = !ui.expanded
        render()
        root.querySelector("[data-history]")?.focus()
      })
      history.dataset.history = "true"
      history.setAttribute("aria-expanded", String(Boolean(ui.expanded)))
      const last = thread.comments?.at(-1)
      root.append(el("div", { style: { padding: "8px 12px", color: colors.muted } }, [
        el("div", { style: composerActionsStyle }, [
          `${thread.comments?.length || 0} comments`, history,
        ]),
        !ui.expanded && last ? el("p", { style: { ...threadCommentBodyStyle, margin: "4px 0", maxHeight: "4.8em", overflow: "auto" } }, last.body) : null,
      ]))
    }
    if (!expanded) return
    root.append(el("ul", { style: { listStyle: "none", margin: "0", padding: "4px 12px 12px" } }, commentRows))
    if (!onReply) return
    const footer = el("footer", { style: { ...threadFooterStyle, marginTop: "0", paddingTop: "0" } })
    root.append(footer)
    if (ui.replyOpen) {
      footer.append(
        commentComposer({
          saveLabel: "Reply",
          placeholder: "Write a reply…",
          initialValue: ui.draft || "",
          embedded: true,
          autoFocus: Boolean(ui.focusReply),
          onChange: (value) => { ui.draft = value },
          onSave: (body) => {
            ui.replyOpen = false
            ui.draft = ""
            onReply?.(thread, body)
            render()
            replyButton?.focus({ preventScroll: true })
          },
          onCancel: () => {
            ui.replyOpen = false
            ui.draft = ""
            render()
            replyButton?.focus({ preventScroll: true })
          },
        })
      )
      ui.focusReply = false
    } else {
      replyButton = button("Reply to this thread…", () => {
        ui.replyOpen = true
        ui.focusReply = true
        render()
      }, { ariaLabel: `Reply to thread on line ${where}` })
      Object.assign(replyButton.style, { width: "100%", justifyContent: "flex-start", minHeight: "44px", padding: "8px 12px", background: "transparent", color: colors.muted, borderRadius: "0" })
      footer.append(replyButton)
    }
  }
  render()
  return root
}
