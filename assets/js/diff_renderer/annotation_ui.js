import { button as baseButton, el } from "./dom.js"
import { COARSE } from "../lib/breakpoints.js"

// Pierre owns the diff body theme. Annotation UI is rendered by Reviews through
// `renderAnnotation`, so it uses Reviews design tokens and inline styles that
// can survive inside Pierre's shadow DOM.
const colors = {
  panel: "var(--ds-panel, #050505)",
  raised: "var(--ds-panel-raised, #0b0b0c)",
  text: "var(--ds-text, #f5f5f5)",
  muted: "var(--ds-muted, #a3a3a3)",
  faint: "var(--ds-faint, #7c7c80)",
  line: "var(--ds-line, #242426)",
  lineStrong: "var(--ds-line-strong, #3a3a3d)",
  add: "var(--ds-add, #25d0a0)",
  blue: "var(--ds-blue)",
}

const fontStack = "var(--font-sans, system-ui, sans-serif)"
// Touch keeps 44px targets, 16px inputs (smaller text makes iOS zoom on
// focus) and no keyboard hints.
const touch = () => Boolean(window.matchMedia?.(COARSE).matches)
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

const composerStyle = { ...bubbleBaseStyle, padding: "10px 12px", marginBottom: "0" }

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
  display: "inline-flex",
  alignItems: "center",
  gap: "4px",
  flexShrink: "0",
  padding: "2px 7px",
  borderRadius: "999px",
  fontSize: "11px",
  lineHeight: "14px",
  fontWeight: "500",
  border: `1px solid ${colors.lineStrong}`,
  background: colors.raised,
  color: colors.muted,
}

const statusPillStyle = {
  open: {
    ...statusPillBaseStyle,
    color: colors.blue,
    background: `color-mix(in srgb, ${colors.blue} 10%, ${colors.panel})`,
    borderColor: `color-mix(in srgb, ${colors.blue} 30%, ${colors.line})`,
  },
  resolved: {
    ...statusPillBaseStyle,
    color: colors.add,
    background: `color-mix(in srgb, ${colors.add} 10%, ${colors.panel})`,
    borderColor: `color-mix(in srgb, ${colors.add} 30%, ${colors.line})`,
  },
  outdated: { ...statusPillBaseStyle, color: colors.faint },
}

const threadRunHeaderStyle = {
  display: "flex",
  alignItems: "center",
  gap: "6px",
  fontWeight: "600",
}
// The body indent and the connector from the avatar are in CSS
// (.review-thread-comments in packet.css).
const threadRunCommentsStyle = {
  margin: "0",
  listStyle: "none",
}
const threadCommentBodyStyle = {
  flex: "1 1 100%",
  minWidth: "0",
  whiteSpace: "normal",
  overflowWrap: "anywhere",
}
const threadCommentTimeStyle = {
  color: colors.faint,
  fontSize: "11px",
  fontWeight: "400",
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

// Annotations are slotted into Pierre's shadow DOM but live in the light DOM,
// so the shared <.ds_button> classes apply to them. The label gets its own
// `.ds-label` box, as in <.ds_button>, so text-box can trim it to cap height;
// a flex button's bare text cannot be trimmed.
function button(label, onClick, attrs = {}) {
  const node = baseButton(el("span", { className: "ds-label" }, label), onClick, attrs)
  node.className = ["ds-button", "is-sm", attrs.primary && "is-primary", attrs.ghost && "is-ghost"].filter(Boolean).join(" ")
  return node
}

// `short` is the compact label shown after the author ("56min", "3h");
// `relative` is the spoken form ("3 hours ago") for the tooltip and
// screen readers.
export function formatRelative(iso, now = Date.now()) {
  const empty = { short: "", relative: "", absolute: "" }
  if (!iso) return empty
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return empty
  const diffMs = t - now
  const absSec = Math.abs(diffMs) / 1000
  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" })
  const units = [
    ["year", "y", 60 * 60 * 24 * 365],
    ["month", "mo", 60 * 60 * 24 * 30],
    ["week", "w", 60 * 60 * 24 * 7],
    ["day", "d", 60 * 60 * 24],
    ["hour", "h", 60 * 60],
    ["minute", "min", 60],
  ]
  const absolute = new Date(t).toISOString()
  for (const [unit, abbr, sec] of units) {
    if (absSec >= sec) {
      const n = Math.floor(absSec / sec)
      return { short: `${n}${abbr}`, relative: rtf.format(Math.sign(diffMs) * n, unit), absolute }
    }
  }
  return { short: "now", relative: rtf.format(0, "second"), absolute }
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

// The same markup and classes as <.ds_avatar_mark> and <.ds_identity>
// (design_system_components.ex), styled by product-shell.css: annotations
// live in the light DOM, so those classes apply here.
export function avatar(user, size = "sm") {
  if (!user) return null
  const handle = user.handle || user.username
  return el("span", { className: `ds-avatar-mark is-${size} is-round`, "aria-hidden": "true" }, [
    user.avatar_url
      ? el("img", { src: user.avatar_url, alt: "", loading: "lazy", decoding: "async" })
      : el("span", {}, (handle || user.display_name || "?").trim().slice(0, 1).toUpperCase() || "?"),
  ])
}

export function identity(user, size = "sm") {
  if (!user) return el("span", { className: "ds-identity-name" }, "reviewer")
  const handle = user.handle || user.username
  const name = user.display_name || handle
  const showHandle = handle && name.toLowerCase() !== handle.toLowerCase()
  return el("span", { className: `ds-identity is-${size}` }, [
    avatar(user, size),
    el("span", { className: "ds-identity-text" }, [
      el("span", { className: "ds-identity-name" }, name),
      showHandle ? el("span", { className: "ds-identity-handle", translate: "no" }, `@${handle}`) : null,
      user.kind === "agent" ? el("span", { className: "ds-identity-agent" }, "Agent") : null,
    ]),
  ])
}

export function threadStatusBadge(status) {
  const label = { open: "Open", resolved: "Resolved", outdated: "Outdated" }[status] || status
  const badge = el("span", { style: statusPillStyle[status] || statusPillBaseStyle }, [])
  if (status === "open" || status === "resolved") {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg")
    for (const [key, value] of Object.entries({
      viewBox: "0 0 24 24", width: "14", height: "14", fill: "none",
      stroke: "currentColor", "stroke-width": "1.8", "stroke-linecap": "round",
      "stroke-linejoin": "round", "aria-hidden": "true", focusable: "false",
    })) svg.setAttribute(key, value)
    svg.style.flexShrink = "0"
    // Match the glyphs' optical center, which sits below the font's line-box center.
    svg.style.transform = "translateY(0.5px)"
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
    path.setAttribute("d", status === "resolved"
      ? "M9 12l2 2 4-4 M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0"
      : "M8 10h8M8 14h5M21 12a9 9 0 0 1-9 9H3l1.5-4A9 9 0 1 1 21 12Z")
    svg.append(path)
    badge.append(svg)
  }
  badge.append(label)
  return badge
}

function bubbleAnchorLink({ anchor, side, status, commentCount }) {
  const label = commentCount > 1 ? "Comments" : "Comment"
  const text = el("span", {}, [
    `${label} on line `,
    el("span", { style: anchorPinpointStyle }, anchorPinpoint(anchor, side)),
  ])
  const children = [text]
  if (status) children.push(threadStatusBadge(status))
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
  focusSelection,
}) {
  // The reply box inside a thread card is a bordered ds-input; the new-comment
  // composer is its own bordered card.
  const fieldStyle = embedded ? { minHeight: "56px", resize: "vertical", lineHeight: "1.5", display: "block" } : textareaStyle
  const textarea = el("textarea", {
    className: embedded ? "ds-input" : null,
    style: touch() ? { ...fieldStyle, fontSize: "16px" } : fieldStyle,
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
    el("div", { style: { ...composerActionsStyle, marginTop: "8px", justifyContent: "space-between" } }, [
      touch() ? null : el("span", { style: { color: colors.muted, fontSize: "11px" } }, `${shortcut} to post · Esc to cancel`),
      el("div", { style: { ...composerActionsStyle, marginLeft: "auto" } }, [
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
  if (!embedded) {
    textarea.addEventListener("focus", () => { node.style.borderColor = "var(--ds-focus, #fff)" })
    textarea.addEventListener("blur", () => { node.style.borderColor = colors.line })
  }

  if (autoFocus) window.requestAnimationFrame(() => {
    if (textarea.isConnected) {
      textarea.focus({ preventScroll: true })
      if (focusSelection) textarea.setSelectionRange(...focusSelection)
    }
  })
  return node
}

function signInHref() {
  const returnTo = window.location.pathname + window.location.search
  return `/auth/github?return_to=${encodeURIComponent(returnTo)}`
}

// GitHub's mark (Primer Octicons mark-github-16). Brand rules: keep it
// unmodified and in one high-contrast colour, so it follows the text colour.
const GITHUB_MARK_PATH =
  "M6.766 11.328c-2.063-.25-3.516-1.734-3.516-3.656 0-.781.281-1.625.75-2.188-.203-.515-.172-1.609.063-2.062.625-.078 1.468.25 1.968.703.594-.187 1.219-.281 1.985-.281.765 0 1.39.094 1.953.265.484-.437 1.344-.765 1.969-.687.218.422.25 1.515.046 2.047.5.593.766 1.39.766 2.203 0 1.922-1.453 3.375-3.547 3.64.531.344.89 1.094.89 1.954v1.625c0 .468.391.734.86.547C13.781 14.359 16 11.53 16 8.03 16 3.61 12.406 0 7.984 0 3.563 0 0 3.61 0 8.031a7.88 7.88 0 0 0 5.172 7.422c.422.156.828-.125.828-.547v-1.25c-.219.094-.5.156-.75.156-1.031 0-1.64-.562-2.078-1.609-.172-.422-.36-.672-.719-.719-.187-.015-.25-.093-.25-.187 0-.188.313-.328.625-.328.453 0 .844.281 1.25.86.313.452.64.655 1.031.655s.641-.14 1-.5c.266-.265.47-.5.657-.656"

function githubMark() {
  const ns = "http://www.w3.org/2000/svg"
  const svg = document.createElementNS(ns, "svg")
  svg.setAttribute("viewBox", "0 0 16 16")
  svg.setAttribute("width", "14")
  svg.setAttribute("height", "14")
  svg.setAttribute("aria-hidden", "true")
  svg.setAttribute("focusable", "false")
  const path = document.createElementNS(ns, "path")
  path.setAttribute("fill", "currentColor")
  path.setAttribute("d", GITHUB_MARK_PATH)
  svg.append(path)
  return svg
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
      el("a", { href: signInHref(), className: "ds-button is-sm is-primary" }, [
        githubMark(),
        el("span", { className: "ds-label" }, "Sign in with GitHub"),
      ]),
      button("Cancel", onCancel),
    ]),
  ])
}

// A link to this page that opens one thread, or one comment in it. It keeps
// the current view and patchset.
export function threadPermalink(threadId, commentId, href = window.location.href) {
  const url = new URL(href)
  url.hash = ""
  for (const key of ["thread", "comment", "section"]) url.searchParams.delete(key)
  url.searchParams.set("thread", threadId)
  if (commentId != null) url.searchParams.set("comment", commentId)
  return url.toString()
}

function strokeIcon(paths) {
  const ns = "http://www.w3.org/2000/svg"
  const svg = document.createElementNS(ns, "svg")
  for (const [k, v] of Object.entries({ viewBox: "0 0 24 24", width: "14", height: "14", fill: "none", stroke: "currentColor", "stroke-width": "2", "stroke-linecap": "round", "stroke-linejoin": "round", "aria-hidden": "true", focusable: "false" })) svg.setAttribute(k, v)
  for (const d of paths) {
    const path = document.createElementNS(ns, "path")
    path.setAttribute("d", d)
    svg.append(path)
  }
  return svg
}
const LINK_ICON = ["M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71", "M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"]
const CHECK_ICON = ["M20 6 9 17l-5-5"]

// A small link icon. Clicking copies the link; it is a real <a>, so a long
// press on a phone also offers the system's Copy Link.
function copyLinkButton(href, label) {
  const status = el("span", { className: "sr-only", role: "status" })
  const icon = strokeIcon(LINK_ICON)
  const link = el("a", {
    href,
    className: "ds-button is-sm is-ghost review-copy-link",
    title: label,
    "aria-label": label,
    onClick: async (event) => {
      event.preventDefault()
      let copied = false
      try {
        await navigator.clipboard.writeText(href)
        copied = true
      } catch {
        // No clipboard access: put the link in the address bar instead.
        window.history.replaceState(window.history.state, "", href)
      }
      status.textContent = copied ? "Link copied" : "Link is in the address bar"
      link.title = status.textContent
      icon.replaceWith(strokeIcon(CHECK_ICON))
      clearTimeout(link._reset)
      link._reset = setTimeout(() => {
        link.querySelector("svg")?.replaceWith(icon)
        link.title = label
        status.textContent = ""
      }, 1600)
    },
  }, [icon, status])
  return link
}

function commentTime(iso, prefix = "") {
  const { short, relative, absolute } = formatRelative(iso)
  if (!short) return null
  return el(
    "time",
    {
      style: threadCommentTimeStyle,
      dateTime: absolute,
      title: `${relative} · ${absolute}`,
      "aria-label": `${prefix}${relative}`,
    },
    `${prefix}${short}`
  )
}

const attributionStyle = {
  flex: "1 1 100%",
  fontSize: "11px",
  color: colors.muted,
}
const attributionSummaryStyle = {
  display: "inline-flex",
  alignItems: "center",
  gap: "6px",
  cursor: "pointer",
  listStyle: "none",
}
const attributionBadgeStyle = {
  border: `1px solid color-mix(in srgb, ${colors.add} 35%, ${colors.line})`,
  borderRadius: "999px",
  padding: "0 6px",
  color: colors.add,
  fontWeight: "600",
}
const attributionListStyle = {
  display: "grid",
  gridTemplateColumns: "max-content 1fr",
  gap: "2px 10px",
  margin: "6px 0 2px",
}

// The verified agent label and its details (issue #154). Only facts the server
// verified are stated as verified; the agent's own name and Agent ID are shown
// as its claims, and parties Poppy 1.0 can't establish are named as such. A
// delegation is shown as signed by Turnkey only when the server verified it
// against Turnkey's poppy-delegation/v1 profile.
export function attributionDetails(attribution, author) {
  if (!attribution || attribution.provider !== "poppy") return null
  const domain = attribution.client_domain || "unknown agent"
  const handle = author?.username ? `@${author.username}` : "this agent"
  const row = (term, ...detail) => [
    el("dt", { style: { color: colors.faint } }, term),
    el("dd", { style: { margin: "0", color: colors.text } }, detail),
  ]
  const claim = (text) => el("span", { style: { color: colors.faint } }, ` (${text})`)
  const turnkey = attribution.delegation_signed_by === "turnkey"

  return el("details", { style: attributionStyle, dataset: { attribution: "poppy" } }, [
    el("summary", { style: attributionSummaryStyle, "aria-label": `Verified agent via ${domain}. Show details.` }, [
      el("span", { style: attributionBadgeStyle }, "Verified agent"),
      el("span", {}, `via ${domain}`),
      attribution.link_revoked ? el("span", { style: { color: colors.faint } }, "· since disconnected") : null,
    ]),
    el("dl", { style: attributionListStyle }, [
      ...row("Acts as", `${handle}, a Reviews agent`),
      ...row("Owner", `@${attribution.owner_username}`, claim(`approved this agent ${formatDate(attribution.approved_at)}`)),
      ...row("Personal Agent", domain, claim("proved by its signing keys")),
      ...(turnkey
        ? row("Turnkey agent", `${attribution.turnkey_agent} in organization ${attribution.turnkey_organization_id}`, claim("its identity key is held in Turnkey"))
        : []),
      ...row("Calls itself", attribution.client_name_claimed || "(no name)", claim("not verified")),
      ...(attribution.agent_id_claimed ? row("Agent ID", "sent", claim("not verified")) : []),
      ...row("Workload", "not established", claim("Poppy 1.0 has no workload proof")),
      ...(turnkey
        ? row("Delegation", "signed by Turnkey", claim("verified: the Turnkey-held identity key vouched for this request's session key"))
        : row("Delegation", "owner approval in Reviews", claim("no signed delegation chain"))),
      ...tokenRow(attribution.token_binding, row, claim),
      ...(attribution.link_revoked ? row("Status", "Disconnected after this comment") : []),
    ]),
  ])
}

// The Token row's value and its faint note: whether the comment's access token
// was bound to the agent's key (RFC 9449). The Session JWT's key is a separate
// check and never shows here. Comments recorded before Reviews kept this have
// no row.
export function tokenBindingText(binding) {
  if (binding === "dpop") return ["Access token bound to agent key", null]
  if (binding === "bearer") return ["Bearer", "not bound to a key"]
  return null
}

function tokenRow(binding, row, claim) {
  const text = tokenBindingText(binding)
  if (!text) return []
  const [value, note] = text
  return note ? row("Token", value, claim(note)) : row("Token", value)
}

function formatDate(iso) {
  const date = iso ? new Date(iso) : null
  return date && !Number.isNaN(date.valueOf()) ? `on ${date.toISOString().slice(0, 10)}` : ""
}

// `body_html` is the server's sanitized rendering of the comment
// (Reviews.Markdown), checked as a string by the Thread schema. Nothing typed
// in the browser goes through innerHTML.
function commentBody(comment, condensed = false) {
  const node = el("div", {
    className: "review-rich-markdown review-comment-markdown",
    style: { ...threadCommentBodyStyle, ...(condensed ? { margin: "4px 0", maxHeight: "4.8em", overflow: "auto" } : {}) },
  })
  node.innerHTML = comment.body_html
  return node
}

export function threadBubble({ thread, onReply, onUpdateStatus, ui = {} }) {
  const runs = groupCommentsByAuthor(thread.comments)
  const commentRows = []

  for (const [index, run] of runs.entries()) {
    // Each comment's time and link sit at the right of its row on wider
    // screens, so a run's comments line up. Phones put the first comment's
    // time after the author name and give later ones their own small line
    // (packet.css), so the body keeps the full width.
    const who = run.author?.username || "reviewer"
    const commentMeta = (comment, head = false) =>
      el("div", { className: head ? "review-comment-meta is-head" : "review-comment-meta" }, [
        commentTime(comment?.inserted_at),
        comment && copyLinkButton(threadPermalink(thread.id, comment.id), `Copy link to ${who}'s comment`),
      ])
    const comments = run.comments.map((comment, i) =>
      // The run's first comment is linked by the whole run, so a comment
      // link lands on the author line too.
      el("li", { className: i ? "review-thread-comment" : "review-thread-comment is-first", dataset: i ? { commentId: comment.id } : {} }, [
        commentMeta(comment),
        commentBody(comment),
        attributionDetails(comment.attribution, run.author),
      ])
    )

    commentRows.push(
      el("li", { style: { marginTop: index ? "8px" : "0" }, dataset: { commentId: run.comments[0]?.id } }, [
        el("header", { style: threadRunHeaderStyle }, [
          identity(run.author),
          commentMeta(run.comments[0], true),
        ]),
        el("ul", { className: "review-thread-comments", style: threadRunCommentsStyle }, comments),
      ])
    )
  }

  let replyButton
  const root = el("div", {
    className: "review-thread-card",
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
      style: { display: "flex", alignItems: "center", gap: "8px", flexWrap: "wrap", minHeight: "36px", padding: "3px 4px 3px 12px", borderBottom: `1px solid ${colors.line}` },
    }, [bubbleAnchorLink({ anchor: thread.anchor, side: thread.side, status: thread.status, commentCount: thread.comments?.length || 0 })])
    const threadLink = copyLinkButton(threadPermalink(thread.id), `Copy link to thread on line ${where}`)
    threadLink.style.marginLeft = "auto"
    header.append(threadLink)
    if (onUpdateStatus && ["open", "resolved"].includes(thread.status)) {
      const status = button(resolved ? "Reopen" : "Resolve", () => {
        ui.expanded = false
        onUpdateStatus(thread, resolved ? "open" : "resolved")
      }, { ariaLabel: `${resolved ? "Reopen" : "Resolve"} thread on line ${where}` })
      header.append(status)
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
        !ui.expanded && last ? commentBody(last, true) : null,
      ]))
    }
    if (!expanded) return
    root.append(el("ul", { style: { listStyle: "none", margin: "0", padding: "8px 12px" } }, commentRows))
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
          focusSelection: ui.replySelection,
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
      ui.replySelection = null
    } else {
      replyButton = button("Reply to this thread…", () => {
        ui.replyOpen = true
        ui.focusReply = true
        render()
      }, { ariaLabel: `Reply to thread on line ${where}`, ghost: true })
      Object.assign(replyButton.style, { width: "100%", justifyContent: "flex-start", borderRadius: "0" })
      footer.append(replyButton)
    }
  }
  render()
  return root
}
