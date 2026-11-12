import * as Diffs from "@pierre/diffs"

import {
  commentComposer,
  signInPrompt,
  threadBubble,
} from "./annotation_ui.js"
import { el } from "./dom.js"
import { MobileConversation } from "./mobile_conversation.js"
import { headerToggleLabel, stopHeaderEvent } from "./header_controls.js"
import {
  annotationSideToSide,
  composerToAnchor,
  threadsToAnnotations,
} from "../lib/translate.js"

const VIRTUAL_LINE_THRESHOLD = 1500
const VIRTUAL_BYTE_THRESHOLD = 200 * 1024
const REVIEWS_DIFF_TYPOGRAPHY_CSS = `
  :host {
    --diffs-font-family: var(--font-mono);
    --diffs-header-font-family: var(--font-sans);
    --diffs-font-size: var(--font-code-size);
    --diffs-line-height: var(--font-code-leading);
    --diffs-font-features: "liga" 0, "calt" 0;
  }
`

// The prefix slot holds a native disclosure button stretched across Pierre's
// header. Metadata controls sit above it as siblings, not nested buttons.
const REVIEWS_DIFF_HEADER_CSS = `
  [data-diffs-header] {
    position: relative;
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
  ::slotted(.reviews-diff-header-metadata) {
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

function parsePatch(rawDiff, filePath) {
  if (!rawDiff || typeof Diffs.parsePatchFiles !== "function") return null
  try {
    const parsed = Diffs.parsePatchFiles(rawDiff, filePath || "patch")
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

function lineTextFromEvent(props) {
  return (props?.lineElement && props.lineElement.textContent) || ""
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
    this.virtualizer = null
    this.threadUI = new Map()
    this.composerDraft = ""
    this.mobileConversation = new MobileConversation()
    this.mobileQuery = window.matchMedia("(max-width: 768px)")
    this.mobileResize = () => {
      this.mobileConversation.close(false)
      this.render()
    }
    this.mobileQuery.addEventListener("change", this.mobileResize)
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
    if (focused) this.restoreHeaderFocus(focused)
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
    this.mobileSelection = composerAt && this.mobileQuery.matches ? { composer: true } : null
    this.render()
  }

  annotations() {
    const real = threadsToAnnotations(this.threads).map((annotation) => ({
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
      if (this.mobileQuery.matches) {
        const marker = el("button", {
          type: "button", className: "reviews-conversation-marker",
          style: { minHeight: "44px", padding: "8px 12px", color: "var(--ds-text)", background: "var(--ds-panel)", border: "1px solid var(--ds-line)", borderRadius: "8px", cursor: "pointer" },
          onclick: () => this.openMobileConversation({ composer: true }, marker),
        }, "Continue comment…")
        if (this.mobileSelection?.composer) this.mobileOpener = marker
        return marker
      }
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

    return el("div", {}, threadList.map((thread) => {
      if (!this.mobileQuery.matches) return this.renderThread(thread)
      const marker = el("button", {
        type: "button", className: "reviews-conversation-marker",
        dataset: { threadId: thread.id },
        style: { display: "block", minHeight: "44px", margin: "4px 0", padding: "8px 12px", color: "var(--ds-text)", background: "var(--ds-panel)", border: "1px solid var(--ds-line)", borderRadius: "8px", cursor: "pointer", font: "13px var(--font-sans, system-ui, sans-serif)" },
        onclick: () => this.openMobileConversation({ threadId: thread.id }, marker),
      }, `${thread.status === "resolved" ? "Resolved" : thread.status === "outdated" ? "Outdated" : "Open"} · ${thread.comments?.length || 0} ${thread.comments?.length === 1 ? "comment" : "comments"}`)
      marker.setAttribute("aria-label", `View ${thread.status} thread on line ${thread.anchor?.line_number_hint}: ${thread.comments?.length || 0} ${thread.comments?.length === 1 ? "comment" : "comments"}`)
      if (this.mobileSelection?.threadId === thread.id) this.mobileOpener = marker
      return marker
    }))
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

  openMobileConversation(selection, opener) {
    this.mobileSelection = selection
    this.mobileOpener = opener
    this.renderMobileConversation()
  }

  renderMobileConversation() {
    if (this.collapsed() || !this.mobileQuery.matches || !this.mobileSelection) {
      this.mobileConversation.close()
      return
    }
    let content
    if (this.mobileSelection.composer && this.composerAt) {
      content = this.composerAt.kind === "signin"
        ? signInPrompt(() => this.setComposerAt(null))
        : commentComposer({
            initialValue: this.composerDraft,
            embedded: true,
            autoFocus: !this.mobileConversation.node,
            onChange: (value) => { this.composerDraft = value },
            onSave: (body) => this.createNewComment(body),
            onCancel: () => this.setComposerAt(null),
          })
    } else {
      const thread = this.threads.find((thread) => thread.id === this.mobileSelection.threadId)
      if (thread) content = this.renderThread(thread)
    }
    if (!content) {
      this.mobileConversation.close()
      return
    }
    Object.assign(content.style, { border: "none", borderRadius: "0", marginBottom: "0" })
    const title = this.mobileSelection.composer
      ? `${this.filePath} · Line ${annotationSideToSide(this.composerAt.side) === "old" ? "−" : "+"}${this.composerAt.lineNumber}`
      : this.filePath
    this.mobileConversation.show(content, title, () => {
      this.mobileSelection = null
    }, () => this.mobileOpener)
  }

  handleLineNumberClick(props) {
    const side = props?.annotationSide || props?.side
    const lineNumber = props?.lineNumber
    if (!side || !lineNumber) return

    if (!this.signedIn) {
      this.setComposerAt({ kind: "signin", side, lineNumber })
      return
    }

    this.setComposerAt({
      kind: "line",
      side,
      lineNumber,
      lineText: lineTextFromEvent(props),
    })
  }

  handleTokenClick(props) {
    const side = props?.side
    const lineNumber = props?.lineNumber
    const tokenText = props?.tokenText || ""
    if (!side || !lineNumber || tokenText.trim().length === 0) return

    if (!this.signedIn) {
      this.setComposerAt({ kind: "signin", side, lineNumber })
      return
    }

    const lineEl =
      (props?.tokenElement && props.tokenElement.closest("[data-line]")) || null
    this.setComposerAt({
      kind: "token",
      side,
      lineNumber,
      lineText: (lineEl && lineEl.textContent) || "",
      lineCharStart: props.lineCharStart,
      lineCharEnd: props.lineCharEnd,
      tokenText,
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
      children.push(
        el(
          "button",
          {
            className: "reviews-diff-header-viewed",
            type: "button",
            "aria-pressed": viewed ? "true" : "false",
            "aria-label": `${viewed ? "Mark unviewed" : "Mark viewed"}: ${this.filePath}${this.hunkUI.hunkLabel ? ` · ${this.hunkUI.hunkLabel}` : ""}`,
            onclick: (event) =>
              stopHeaderEvent(event, () => this.onSetHunkViewed?.(!viewed)),
          },
          viewed ? "Viewed" : viewLabel || "Mark viewed"
        )
      )
    }

    return el("div", { className: "reviews-diff-header-metadata" }, children)
  }

  options() {
    return {
      theme: currentPierreTheme(),
      diffStyle: this.diffStyle,
      collapsed: this.collapsed(),
      unsafeCSS: REVIEWS_DIFF_TYPOGRAPHY_CSS + (this.hunkUI ? REVIEWS_DIFF_HEADER_CSS : ""),
      renderHeaderPrefix: () => this.renderHeaderPrefix(),
      renderHeaderMetadata: () => this.renderHeaderMetadata(),
      renderAnnotation: (annotation) => this.renderAnnotation(annotation),
      onLineNumberClick: (props) => this.handleLineNumberClick(props),
      onTokenClick: (props) => this.handleTokenClick(props),
    }
  }

  renderArgs() {
    const args = {
      containerWrapper: this.container,
      lineAnnotations: this.annotations(),
    }
    if (this.fileDiff) args.fileDiff = this.fileDiff
    else args.patch = this.rawDiff
    return args
  }

  render() {
    this.cleanUp(false)
    this.container.replaceChildren()
    this.container.dataset.virtualized = "false"

    const options = this.options()
    const renderArgs = this.renderArgs()

    if (
      !this.collapsed() &&
      shouldVirtualize({ rawDiff: this.rawDiff, fileDiff: this.fileDiff, diffStyle: this.diffStyle })
    ) {
      if (this.tryRenderVirtualized(options, renderArgs)) {
        this.renderMobileConversation()
        return
      }
    }

    this.instance = new Diffs.FileDiff(options)
    this.instance.render(renderArgs)
    this.renderMobileConversation()
  }

  tryRenderVirtualized(options, renderArgs) {
    if (!Diffs.Virtualizer || !Diffs.VirtualizedFileDiff || !this.fileDiff) return false

    try {
      const contentWrapper = el("div", { className: "review-virtualized-diff-content" })
      this.container.append(contentWrapper)
      this.virtualizer = new Diffs.Virtualizer({
        overscrollSize: 800,
        intersectionObserverMargin: 800,
        resizeDebugging: false,
      })
      this.virtualizer.setup(document, contentWrapper)
      this.instance = new Diffs.VirtualizedFileDiff(
        options,
        this.virtualizer,
        {
          lineHeight: 20,
          fileHeaderHeight: 44,
          annotationEstimateHeight: 96,
        }
      )
      this.instance.render({ ...renderArgs, containerWrapper: contentWrapper })
      this.container.dataset.virtualized = "true"
      return true
    } catch (err) {
      // eslint-disable-next-line no-console
      console.warn("[DiffRenderer] virtualized render unavailable; falling back to FileDiff:", err)
      this.cleanUp(false)
      this.container.replaceChildren()
      return false
    }
  }

  cleanUp(clear = true) {
    if (clear) {
      this.mobileQuery.removeEventListener("change", this.mobileResize)
      this.mobileConversation.close(false)
      this.threadUI.clear()
    }
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
