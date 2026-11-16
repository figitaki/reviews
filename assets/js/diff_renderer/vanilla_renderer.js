import * as Diffs from "@pierre/diffs"
import { isMarkdown } from "../lib/markdown.js"
import { discussionCount, markdownPreview, markdownPreviewState, previewNotice } from "./markdown_preview.js"

import {
  commentComposer,
  signInPrompt,
  threadBubble,
  threadStatusBadge,
} from "./annotation_ui.js"
import { el } from "./dom.js"
import { headerToggleLabel, stopHeaderEvent } from "./header_controls.js"
import {
  annotationSideToSide,
  composerToAnchor,
  sideToAnnotationSide,
  threadsToAnnotations,
} from "../lib/translate.js"

const VIRTUAL_LINE_THRESHOLD = 1500
const VIRTUAL_BYTE_THRESHOLD = 200 * 1024
// Machine-written lockfiles have one long line per entry. On phones they scroll
// sideways instead of wrapping, so each line stays one row and the package
// names and versions at the start of each line are easy to scan.
const LOCKFILE = /(^|\/)(package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|Cargo\.lock|Gemfile\.lock|mix\.lock|composer\.lock|poetry\.lock|uv\.lock|Pipfile\.lock|go\.sum|flake\.lock|Package\.resolved|Podfile\.lock|pubspec\.lock)$/
const REVIEWS_DIFF_TYPOGRAPHY_CSS = `
  :host {
    --diffs-font-family: var(--font-mono);
    --diffs-header-font-family: var(--font-sans);
    --diffs-font-size: var(--font-code-size);
    --diffs-line-height: var(--font-code-leading);
    --diffs-font-features: "liga" 0, "calt" 0;
  }
  /* Pierre's comment button is one line tall. Widen its touch area without
     covering the neighbouring rows' gutter. */
  @media (pointer: coarse) {
    [data-utility-button]::before,
    .reviews-thread-marker::before { inset: -6px -12px; }
  }
  /* Phones hide line numbers. The gutter keeps the change bar and is just
     wide enough for Pierre's comment button (at left: 6px) and our badge. */
  [data-disable-line-numbers] :is([data-column-number], [data-gutter-buffer]) {
    min-width: calc(1lh + 14px);
  }
  /* Phones: lines with threads get a button shaped like Pierre's comment
     button, in the same spot, with a count badge. */
  .reviews-thread-marker {
    position: absolute;
    top: 0;
    left: 6px;
    z-index: 5;
    display: flex;
    align-items: center;
    justify-content: center;
    width: 1lh;
    height: 1lh;
    padding: 0;
    border: none;
    border-radius: 4px;
    background-color: var(--diffs-modified-base);
    color: var(--diffs-bg);
    cursor: pointer;
    touch-action: manipulation;
  }
  [data-reviews-discussed] {
    --diffs-line-bg: light-dark(
      color-mix(in lab, var(--diffs-computed-diff-line-bg) 82%, var(--diffs-modified-base)),
      color-mix(in lab, var(--diffs-computed-diff-line-bg) 75%, var(--diffs-modified-base))
    );
  }
  .reviews-thread-marker::before { content: ""; position: absolute; inset: 0 0 0 -4px; }
  .reviews-thread-marker[aria-expanded="true"] { box-shadow: 0 0 0 2px var(--diffs-bg), 0 0 0 3px var(--diffs-modified-base); }
  .reviews-thread-marker svg {
    width: 14px;
    height: 14px;
    fill: none;
    stroke: currentColor;
    stroke-width: 2;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
  .reviews-thread-marker-count {
    position: absolute;
    top: -5px;
    right: -7px;
    min-width: 14px;
    height: 14px;
    padding: 0 3px;
    box-sizing: border-box;
    border: 1px solid var(--diffs-modified-base);
    border-radius: 7px;
    background: var(--diffs-bg);
    color: var(--diffs-modified-base);
    font: 600 10px/12px var(--diffs-header-font-family, system-ui, sans-serif);
    text-align: center;
    font-variant-numeric: tabular-nums;
  }
  /* Phones: "N unmodified lines" separators span the card edge to edge and
     drop their rounded corners, matching the card (packet.css, 768px). */
  @media (max-width: 768px) {
    [data-separator="line-info"] [data-separator-wrapper] {
      padding-inline: 0;
    }
    [data-separator="line-info"] :is([data-separator-wrapper], [data-separator-content], [data-expand-button]) {
      border-radius: 0;
    }
  }
`

// The prefix slot holds a native disclosure button stretched across Pierre's
// header. Metadata controls sit above it as siblings, not nested buttons.
const REVIEWS_DIFF_HEADER_CSS = `
  [data-diffs-header] {
    position: sticky;
    top: var(--review-main-nav-h, 0px);
    z-index: 10;
    min-height: 44px;
    padding-inline: 12px;
    transition: background-color 140ms ease;
  }
  [data-diffs-header]:hover {
    background: var(--review-hover);
  }
  [data-header-content] {
    position: static;
  }
  [data-metadata] {
    pointer-events: none;
  }
  ::slotted([slot="header-metadata"]) {
    position: relative;
    z-index: 2;
    pointer-events: none;
  }
`

function currentPierreTheme() {
  const explicit = document.documentElement.dataset.theme
  if (explicit === "dark") return "pierre-dark"
  if (explicit === "light") return "pierre-light"
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches
    ? "pierre-dark"
    : "pierre-light"
}

export function parsePatch(rawDiff, filePath) {
  if (!rawDiff || typeof Diffs.parsePatchFiles !== "function") return null
  try {
    const parsed = Diffs.parsePatchFiles(rawDiff, { cacheKeyPrefix: filePath || "patch" })
    const files = Array.isArray(parsed)
      ? parsed.flatMap((patch) => patch?.files || [])
      : []
    if (files.length === 0) return null
    return files.find((diff) => diff?.name === filePath || diff?.prevName === filePath) || files[0]
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error("[DiffRenderer] failed to parse patch:", err)
    return null
  }
}

function rawByteLength(text) {
  if (!text) return 0
  if (window.TextEncoder) return new TextEncoder().encode(text).length
  return text.length
}

function renderedLineCount(fileDiff, diffStyle) {
  if (!fileDiff) return 0
  if (diffStyle === "unified") return fileDiff.unifiedLineCount || 0
  return fileDiff.splitLineCount || fileDiff.unifiedLineCount || 0
}

function shouldVirtualize({ rawDiff, fileDiff, diffStyle }) {
  return (
    rawByteLength(rawDiff) >= VIRTUAL_BYTE_THRESHOLD ||
    renderedLineCount(fileDiff, diffStyle) >= VIRTUAL_LINE_THRESHOLD
  )
}

// A line anchor, or a token anchor when the reader selected text within the
// line before pressing the gutter button (Pierre keeps the selection intact).
function lineAnchor(lineElement, side, lineNumber) {
  const anchor = { kind: "line", side, lineNumber, lineText: lineElement?.textContent || "" }
  const selection = lineElement?.getRootNode().getSelection?.() || document.getSelection()
  if (!lineElement || !selection?.rangeCount || selection.isCollapsed) return anchor
  const range = selection.getRangeAt(0)
  const tokenText = range.toString()
  if (!lineElement.contains(range.startContainer) || !lineElement.contains(range.endContainer) ||
      !tokenText.trim()) return anchor
  const before = range.cloneRange()
  before.selectNodeContents(lineElement)
  before.setEnd(range.startContainer, range.startOffset)
  const lineCharStart = before.toString().length
  return { ...anchor, kind: "token", tokenText, lineCharStart, lineCharEnd: lineCharStart + tokenText.length }
}

export function hunkViewLabel(hunkUI) {
  if (!hunkUI) return ""
  if (hunkUI.hunkViewed) return "Viewed"
  if (hunkUI.hunkPartiallyViewed) return "Partially viewed"
  return hunkUI.hunkViewState || ""
}

export class VanillaDiffRenderer {
  constructor({
    container,
    filePath,
    rawDiff,
    fullDiff,
    signedIn,
    threads,
    diffStyle,
    hunkUI,
    onCreateComment,
    onUpdateThreadStatus,
    onToggleHunk,
    onSetHunkViewed,
  }) {
    this.container = container
    this.filePath = filePath
    this.rawDiff = rawDiff
    this.signedIn = signedIn
    this.threads = threads
    this.diffStyle = diffStyle
    this.hunkUI = hunkUI || null
    this.onCreateComment = onCreateComment
    this.onUpdateThreadStatus = onUpdateThreadStatus
    this.onToggleHunk = onToggleHunk
    this.onSetHunkViewed = onSetHunkViewed
    this.composerAt = null
    this.fileDiff = parsePatch(rawDiff, filePath)
    this.instance = null
    this.headerInstance = null
    this.virtualizer = null
    this.threadUI = new Map()
    // Phones keep threads out of the diff flow: a gutter button per commented
    // line opens that line's threads inline. Lines open now, as "side:line".
    this.compactQuery = window.matchMedia("(max-width: 768px)")
    this.onCompactChange = () => this.render()
    this.compactQuery.addEventListener("change", this.onCompactChange)
    this.openLines = new Set()
    this.composerDraft = ""
    // For touch, Pierre reveals its button in its own pointerdown handler,
    // which runs before this one.
    this.onPointerDown = () => this.labelGutterUtility()
    container.addEventListener("pointerdown", this.onPointerDown)
    this.hasMarkdownPreview = isMarkdown(filePath) && (this.fileDiff?.hunks.length || 0) > 0
    if (this.hasMarkdownPreview) {
      // Added/deleted files carry the whole document even in a sliced packet hunk.
      const previewPatch = fullDiff || rawDiff
      this.markdownState = markdownPreviewState(previewPatch, fullDiff ? parsePatch(fullDiff, filePath) : this.fileDiff)
      const reviewPath = window.location.pathname.replace(/\/changes\/?$/, "")
      this.modeKey = `reviews:markdown-view:${reviewPath}:${filePath}`
      try {
        const saved = window.localStorage.getItem(this.modeKey)
        if (saved === "source" || saved === "preview") this.preferredPreview = saved === "preview"
      } catch { /* Storage may be disabled; the choice still lasts for this mount. */ }
    }
  }

  get preview() {
    return !this.markdownState?.reason && (this.preferredPreview ?? true)
  }

  // Toolbar choices are saved; jumping to a discussion only switches this visit.
  selectMarkdownMode(preview, persist = true) {
    this.preferredPreview = preview
    if (persist) {
      try { window.localStorage.setItem(this.modeKey, preview ? "preview" : "source") } catch { /* Optional persistence. */ }
    }
    this.render()
    this.container.querySelector('.review-markdown-toolbar [aria-pressed="true"]')?.focus({ preventScroll: true })
  }

  discussionButton(header = false) {
    const count = discussionCount(this.threads, this.fileDiff?.hunks)
    if (!count) return null
    return el("button", {
      type: "button",
      className: header ? "reviews-diff-header-discussions" : "review-button review-button-ghost review-markdown-discussions",
      "aria-label": `Show ${count} ${count === 1 ? "discussion" : "discussions"} in Source`,
      onclick: event => stopHeaderEvent(event, () => {
        this.selectMarkdownMode(false, false)
        if (this.collapsed()) {
          this.focusSourceOnExpand = true
          this.onToggleHunk?.()
        }
      }),
    }, `${count} ${count === 1 ? "discussion" : "discussions"}`)
  }

  update({ threads }) {
    if (threads) this.threads = threads
    this.render()
  }

  updateHunkUI(hunkUI) {
    const next = hunkUI || null
    if (JSON.stringify(next) === JSON.stringify(this.hunkUI)) return
    this.hunkUI = next
    const focused = this.focusedHeaderControl()
    this.render()
    if (this.focusSourceOnExpand && !this.collapsed()) {
      this.focusSourceOnExpand = false
      this.container.querySelector('.review-markdown-toolbar [aria-pressed="true"]')?.focus({ preventScroll: true })
    } else if (focused) this.restoreHeaderFocus(focused)
  }

  // Re-rendering rebuilds Pierre's header, which destroys the slotted control
  // that had keyboard focus (expand/collapse, Mark viewed). Remember which one
  // it was and focus its replacement so focus never drops to <body>.
  focusedHeaderControl() {
    const active = document.activeElement
    if (!active || !this.container.contains(active)) return null
    const control = active.closest(".reviews-diff-header-toggle, .reviews-diff-header-viewed")
    return control ? control.classList[0] : null
  }

  restoreHeaderFocus(className) {
    const focus = () => {
      const control = this.container.querySelector(`.${className}`)
      if (control) control.focus({ preventScroll: true })
      return Boolean(control)
    }
    if (!focus()) window.requestAnimationFrame(focus)
  }

  collapsed() {
    return Boolean(this.hunkUI && !this.hunkUI.hunkExpanded)
  }

  updateStyle(diffStyle) {
    if (diffStyle === this.diffStyle) return
    this.diffStyle = diffStyle
    this.render()
  }

  setComposerAt(composerAt) {
    this.composerAt = composerAt
    this.composerDraft = ""
    this.render()
  }

  // Pierre's gutter "+" is the only way to start a comment, so selecting text
  // stays native. A drag reports a range, but comments anchor to one line:
  // the line where the gesture ended.
  commentFromGutter(range) {
    const side = range.endSide || range.side
    const anchor = lineAnchor(this.renderedLine(side, range.end), side, range.end)
    this.setComposerAt(this.signedIn ? anchor : { ...anchor, kind: "signin" })
  }

  renderedLine(side, lineNumber, attribute = "line") {
    const root = this.sourceContainer?.querySelector("diffs-container")?.shadowRoot
    const unifiedSide = side === "deletions"
      ? '[data-line-type="change-deletion"]'
      : ':not([data-line-type="change-deletion"])'
    const cell = `[data-${attribute}="${lineNumber}"]`
    return root?.querySelector(`[data-${side}] ${cell}, [data-unified] ${cell}${unifiedSide}`)
  }

  compact() {
    return this.compactQuery.matches
  }

  toggleLine(side, lineNumber) {
    const key = `${side}:${lineNumber}`
    if (this.openLines.has(key)) this.openLines.delete(key)
    else this.openLines.add(key)
    this.render()
  }

  // Pierre has no read-only gutter decorations, so the buttons go into its
  // line-number cells after each render, including virtualized re-renders.
  placeThreadMarkers() {
    const root = this.sourceContainer?.querySelector("diffs-container")?.shadowRoot
    if (!root) return
    root.querySelectorAll(".reviews-thread-marker").forEach((marker) => marker.remove())
    if (!this.compact()) return
    for (const { side, lineNumber, metadata } of threadsToAnnotations(this.threads)) {
      const cell = this.renderedLine(side, lineNumber, "column-number")
      if (!cell) continue
      const threads = metadata.threads
      const comments = threads.reduce((sum, thread) => sum + (thread.comments?.length || 0), 0)
      const open = this.openLines.has(`${side}:${lineNumber}`)
      const sign = side === "deletions" ? "−" : "+"
      const what = threads.length > 1
        ? `${threads.length} threads, ${comments} comments`
        : `${comments} ${comments === 1 ? "comment" : "comments"}`
      const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg")
      icon.setAttribute("viewBox", "0 0 24 24")
      icon.setAttribute("aria-hidden", "true")
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
      path.setAttribute("d", "M8 10h8M8 14h5M21 12a9 9 0 0 1-9 9H3l1.5-4A9 9 0 1 1 21 12Z")
      icon.append(path)
      cell.append(el("button", {
        type: "button",
        className: "reviews-thread-marker",
        "aria-expanded": String(open),
        "aria-label": `${open ? "Hide" : "Show"} ${what} on line ${sign}${lineNumber}`,
        // Keep Pierre from revealing its "+" on the same cell.
        onpointerdown: (event) => event.stopPropagation(),
        onclick: (event) => {
          event.stopPropagation()
          this.toggleLine(side, lineNumber)
        },
      }, [icon, el("span", { className: "reviews-thread-marker-count", "aria-hidden": "true" }, String(comments))]))
    }
    // Lines being discussed stay highlighted. This is not Pierre's line
    // selection, which would pin its "+" to that line.
    const lines = [...this.openLines]
    if (this.composerAt) lines.push(`${this.composerAt.side}:${this.composerAt.lineNumber}`)
    for (const key of lines) {
      const [side, line] = key.split(":")
      for (const attribute of ["line", "column-number"]) {
        this.renderedLine(side, line, attribute)?.setAttribute("data-reviews-discussed", "")
      }
    }
  }

  // Pierre shows its button on hover, or on pointerdown on a line number for
  // touch, but gives it no accessible name. Name it for the row it is on.
  labelGutterUtility() {
    const line = this.instance?.getHoveredLine?.()
    const root = this.sourceContainer?.querySelector("diffs-container")?.shadowRoot
    const button = root?.querySelector("[data-utility-button]")
    if (!line || !button) return
    button.setAttribute("aria-label", `Comment on line ${line.lineNumber}`)
    button.title = button.getAttribute("aria-label")
  }

  annotations() {
    const real = threadsToAnnotations(this.threads)
      .filter(({ side, lineNumber }) => !this.compact() || this.openLines.has(`${side}:${lineNumber}`))
      .map((annotation) => ({
      ...annotation,
      metadata: { kind: "real", ...annotation.metadata },
    }))

    if (!this.composerAt) return real

    return [
      ...real,
      {
        side: this.composerAt.side,
        lineNumber: this.composerAt.lineNumber,
        metadata: {
          kind: "composer",
          composerKind: this.composerAt.kind,
          tokenText: this.composerAt.tokenText || "",
        },
      },
    ]
  }

  createNewComment(body) {
    if (!this.composerAt) return
    const anchor = composerToAnchor(this.composerAt)
    this.onCreateComment({
      file_path: this.filePath,
      side: annotationSideToSide(this.composerAt.side),
      body,
      thread_anchor: anchor,
      line_text: this.composerAt.lineText || "",
    })
    // Show the new thread under its line once it arrives.
    if (this.compact()) this.openLines.add(`${this.composerAt.side}:${this.composerAt.lineNumber}`)
    this.setComposerAt(null)
  }

  replyToThread(thread, body) {
    if (!this.signedIn) return
    this.onCreateComment({
      file_path: thread.file_path,
      side: thread.side,
      body,
      thread_id: thread.id,
      thread_anchor: thread.anchor,
    })
  }

  updateThreadStatus(thread, status) {
    if (!this.signedIn) return
    this.onUpdateThreadStatus?.({
      file_path: thread.file_path,
      thread_id: thread.id,
      status,
    })
  }

  renderAnnotation(annotation) {
    const meta = annotation.metadata || {}
    if (meta.kind === "composer") {
      return meta.composerKind === "signin"
        ? signInPrompt(() => this.setComposerAt(null))
        : commentComposer({
            initialValue: this.composerDraft,
            onChange: (value) => { this.composerDraft = value },
            onSave: (body) => this.createNewComment(body),
            onCancel: () => this.setComposerAt(null),
          })
    }

    const threadList = meta.threads || []

    return el("div", {}, threadList.map((thread) => this.renderThread(thread)))
  }

  renderThread(thread) {
    if (!this.threadUI.has(thread.id)) this.threadUI.set(thread.id, {})
    return threadBubble({
      thread,
      ui: this.threadUI.get(thread.id),
      onReply: this.signedIn ? (t, body) => this.replyToThread(t, body) : null,
      onUpdateStatus: this.signedIn ? (t, status) => this.updateThreadStatus(t, status) : null,
    })
  }

  openThread(id) {
    const thread = this.threads.find(thread => String(thread.id) === String(id))
    if (!thread) return
    // Threads live in Source. Navigating to one is not a saved view choice.
    this.preferredPreview = false
    this.threadUI.set(thread.id, { ...this.threadUI.get(thread.id), expanded: true })
    this.focusedThreadId = thread.id
    this.pendingThreadFocus = thread.id
    this.openLines.add(`${sideToAnnotationSide(thread.side)}:${thread.anchor?.line_number_hint}`)
    this.render()
  }

  focusPendingThread() {
    if (!this.pendingThreadFocus) return
    requestAnimationFrame(() => {
      if (!this.pendingThreadFocus) return
      const target = this.container.querySelector(`[data-thread-id="${this.pendingThreadFocus}"]`)
      if (!target) return
      this.pendingThreadFocus = null
      target.style.scrollMarginTop = "calc(var(--review-main-nav-h) + 60px)"
      if (this.compact()) {
        // Scroll the page only. On a lockfile's sideways-scrolling code,
        // scrollIntoView also scrolls the code to Pierre's sticky annotation
        // and hides the start of every line.
        const margin = Number.parseFloat(getComputedStyle(target).scrollMarginTop) || 0
        window.scrollTo({ top: window.scrollY + target.getBoundingClientRect().top - margin, behavior: "instant" })
      } else {
        target.scrollIntoView({ block: "start", behavior: "instant" })
      }
      target.tabIndex = -1
      target.focus({ preventScroll: true })
    })
  }

  // Keep Pierre's path, status icon and counts. The disclosure button uses
  // its prefix slot and covers the row; the viewed control stays independent.
  renderHeaderPrefix() {
    if (!this.hunkUI) return null

    const expanded = this.hunkUI.hunkExpanded

    const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg")
    icon.setAttribute("class", "reviews-diff-header-chevron")
    icon.setAttribute("viewBox", "0 0 24 24")
    icon.setAttribute("aria-hidden", "true")
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path")
    path.setAttribute("d", "m9 5 7 7-7 7")
    icon.append(path)

    const toggle = el("button",
      {
        className: `reviews-diff-header-toggle${expanded ? " is-expanded" : ""}`,
        type: "button",
        "aria-expanded": expanded ? "true" : "false",
        "aria-label": headerToggleLabel(this.filePath, this.hunkUI),
        title: this.hunkUI.hunkDetails || this.filePath,
        onclick: (event) => stopHeaderEvent(event, this.onToggleHunk),
      },
      [icon]
    )
    return el("span", { className: "reviews-diff-header-prefix" }, [toggle])
  }

  renderHeaderMetadata() {
    if (!this.hunkUI) return null

    const children = []
    if (this.hasMarkdownPreview && this.collapsed()) children.push(this.discussionButton(true))

    if (this.hunkUI.hunkLabel) {
      children.push(
        el(
          "span",
          {
            className: "reviews-diff-header-hunk",
            title: this.hunkUI.hunkDetails || null,
          },
          this.hunkUI.hunkLabel
        )
      )
    }

    const viewLabel = hunkViewLabel(this.hunkUI)
    if (viewLabel && !this.hunkUI.signedIn) {
      children.push(
        el(
          "span",
          {
            className: `reviews-diff-header-state${this.hunkUI.hunkViewed ? " is-viewed" : ""}`,
          },
          viewLabel
        )
      )
    }

    if (this.hunkUI.signedIn) {
      const viewed = this.hunkUI.hunkViewed
      const check = document.createElementNS("http://www.w3.org/2000/svg", "svg")
      check.setAttribute("viewBox", "0 0 24 24")
      check.setAttribute("aria-hidden", "true")
      const checkPath = document.createElementNS("http://www.w3.org/2000/svg", "path")
      checkPath.setAttribute("d", "m8 12 3 3 5-6 M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0")
      check.append(checkPath)
      children.push(
        el(
          "button",
          {
            className: "reviews-diff-header-viewed",
            type: "button",
            "aria-pressed": viewed ? "true" : "false",
            title: viewed ? "Viewed · mark unviewed" : "Mark viewed and collapse",
            "aria-label": `${viewed ? "Mark unviewed" : "Mark viewed"}: ${this.filePath}${this.hunkUI.hunkLabel ? ` · ${this.hunkUI.hunkLabel}` : ""}`,
            onclick: (event) =>
              stopHeaderEvent(event, () => this.onSetHunkViewed?.(!viewed)),
          },
          viewed ? [check] : viewLabel || "Mark viewed"
        )
      )
    }

    return el("div", { className: "reviews-diff-header-metadata" }, children)
  }

  options() {
    return {
      theme: currentPierreTheme(),
      diffStyle: this.diffStyle,
      overflow:
        this.diffStyle === "unified" && !(this.compact() && LOCKFILE.test(this.filePath)) ? "wrap" : "scroll",
      collapsed: this.collapsed(),
      // Phones drop line numbers; the gutter holds only the comment buttons.
      disableLineNumbers: this.compact(),
      unsafeCSS: REVIEWS_DIFF_TYPOGRAPHY_CSS + (this.hunkUI ? REVIEWS_DIFF_HEADER_CSS : ""),
      renderHeaderPrefix: () => this.renderHeaderPrefix(),
      renderHeaderMetadata: () => this.renderHeaderMetadata(),
      renderAnnotation: (annotation) => this.renderAnnotation(annotation),
      onPostRender: (_node, _instance, phase) => {
        if (phase === "unmount") return
        this.placeThreadMarkers()
        this.focusPendingThread()
      },
      enableGutterUtility: true,
      onGutterUtilityClick: (range) => this.commentFromGutter(range),
      onLineEnter: () => this.labelGutterUtility(),
    }
  }

  renderArgs() {
    const args = {
      containerWrapper: this.sourceContainer || this.container,
      lineAnnotations: this.annotations(),
    }
    if (this.fileDiff) args.fileDiff = this.fileDiff
    else args.patch = this.rawDiff
    return args
  }

  render() {
    // An incoming update replaces annotation DOM. Preserve only the active
    // desktop reply editor, not every draft that happens to be open.
    const active = document.activeElement
    const threadId = active?.closest?.("[data-thread-id]")?.dataset.threadId
    if (active?.tagName === "TEXTAREA" &&
        this.container.contains(active) && threadId) {
      const thread = this.threads.find(thread => String(thread.id) === threadId)
      const ui = thread && this.threadUI.get(thread.id)
      if (ui) {
        ui.focusReply = true
        ui.replySelection = [active.selectionStart, active.selectionEnd, active.selectionDirection]
      }
    }
    // Rebuilding empties the file for a moment. Hold its height until the new
    // diff has laid out, or the page clamps the scroll position and the reader
    // loses their line (virtualized files measure rows after render).
    this.container.style.minHeight = `${this.container.offsetHeight}px`
    requestAnimationFrame(() => requestAnimationFrame(() => { this.container.style.minHeight = "" }))
    this.cleanUp(false)
    this.container.replaceChildren()
    this.container.dataset.virtualized = "false"

    this.sourceContainer = this.container
    if (this.hasMarkdownPreview) {
      const headerContainer = el("div", { className: "reviews-markdown-sticky-header" })
      this.container.append(headerContainer)
      const toolbar = el("div", { className: "review-markdown-toolbar", role: "group", "aria-label": "Markdown view" })
      for (const [label, preview] of [["Source", false], ["Preview", true]]) {
        toolbar.append(el("button", {
          type: "button", className: "review-button review-button-ghost",
          "aria-pressed": String(this.preview === preview),
          disabled: preview && Boolean(this.markdownState.reason),
          title: preview ? this.markdownState.reason : null,
          onclick: () => this.selectMarkdownMode(preview),
        }, label))
      }
      toolbar.append(el("p", { className: "review-markdown-notice", role: "status" }, previewNotice(this.preview, this.markdownState)))
      const discussions = this.discussionButton()
      if (discussions) toolbar.append(discussions)
      this.sourceContainer = el("div")
      if (!this.collapsed()) {
        this.container.append(toolbar, this.sourceContainer)
        if (this.preview) {
          // This detached subtree survives mode, thread, theme and viewed updates.
          this.markdownContent ||= markdownPreview(this.markdownState, this.diffStyle)
          this.markdownContent.dataset.diffStyle = this.diffStyle
          this.sourceContainer.append(this.markdownContent)
        } else {
          this.renderSource({ ...this.options(), disableFileHeader: true })
        }
      }
      // One shared Pierre header stays above the notice in both modes.
      this.headerInstance = new Diffs.FileDiff({ ...this.options(), collapsed: true })
      this.headerInstance.render({ ...this.renderArgs(), containerWrapper: headerContainer, lineAnnotations: [] })
      return
    }

    this.renderSource(this.options())
  }

  renderSource(options) {
    const renderArgs = this.renderArgs()

    if (
      !this.collapsed() && !this.focusedThreadId &&
      shouldVirtualize({ rawDiff: this.rawDiff, fileDiff: this.fileDiff, diffStyle: this.diffStyle })
    ) {
      if (this.tryRenderVirtualized(options, renderArgs)) return
    }

    this.instance = new Diffs.FileDiff(options)
    this.instance.render(renderArgs)
  }

  tryRenderVirtualized(options, renderArgs) {
    if (!Diffs.Virtualizer || !Diffs.VirtualizedFileDiff || !this.fileDiff) return false

    try {
      const contentWrapper = el("div", { className: "review-virtualized-diff-content" })
      this.sourceContainer.append(contentWrapper)
      this.virtualizer = new Diffs.Virtualizer({
        overscrollSize: 800,
        intersectionObserverMargin: 800,
        resizeDebugging: false,
      })
      this.virtualizer.setup(document, contentWrapper)
      this.instance = new Diffs.VirtualizedFileDiff(
        options,
        this.virtualizer,
        // Partial<VirtualFileMetrics>: Pierre fills in the rest from
        // DEFAULT_VIRTUAL_FILE_METRICS. There is no annotation estimate:
        // rows taller than lineHeight (annotations, wrapped lines) are
        // measured after render.
        {
          lineHeight: 20,
          diffHeaderHeight: 44,
        }
      )
      this.instance.render({ ...renderArgs, containerWrapper: contentWrapper })
      this.container.dataset.virtualized = "true"
      return true
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn("[DiffRenderer] virtualized render unavailable; falling back to FileDiff:", err)
      this.cleanUp(false)
      this.sourceContainer.replaceChildren()
      return false
    }
  }

  cleanUp(clear = true) {
    if (clear) {
      this.container.removeEventListener("pointerdown", this.onPointerDown)
      this.compactQuery.removeEventListener("change", this.onCompactChange)
      this.threadUI.clear()
    }
    this.headerInstance?.cleanUp?.()
    this.headerInstance = null
    try {
      this.instance?.cleanUp?.()
    } finally {
      this.instance = null
    }
    try {
      this.virtualizer?.cleanUp?.()
      this.virtualizer?.destroy?.()
    } finally {
      this.virtualizer = null
    }
    if (clear) this.container.replaceChildren()
  }
}
