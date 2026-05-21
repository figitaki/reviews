import * as Diffs from "@pierre/diffs"

import {
  commentComposer,
  signInPrompt,
  threadBubble,
} from "./annotation_ui.js"
import { el } from "./dom.js"
import {
  annotationSideToSide,
  composerToAnchor,
  threadsToAnnotations,
} from "../lib/translate.js"

const VIRTUAL_LINE_THRESHOLD = 1500
const VIRTUAL_BYTE_THRESHOLD = 200 * 1024
const REVIEWS_DIFF_TYPOGRAPHY_CSS = `
  :host {
    --diffs-font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    --diffs-header-font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    --diffs-font-size: 13px;
    --diffs-line-height: 20px;
    --diffs-font-features: "liga" 0, "calt" 0;
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

export class VanillaDiffRenderer {
  constructor({
    container,
    filePath,
    rawDiff,
    signedIn,
    threads,
    diffStyle,
    onCreateComment,
  }) {
    this.container = container
    this.filePath = filePath
    this.rawDiff = rawDiff
    this.signedIn = signedIn
    this.threads = threads
    this.diffStyle = diffStyle
    this.onCreateComment = onCreateComment
    this.composerAt = null
    this.fileDiff = parsePatch(rawDiff, filePath)
    this.instance = null
    this.virtualizer = null
  }

  update({ threads }) {
    if (threads) this.threads = threads
    this.render()
  }

  updateStyle(diffStyle) {
    this.diffStyle = diffStyle
    this.render()
  }

  setComposerAt(composerAt) {
    this.composerAt = composerAt
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

  renderAnnotation(annotation) {
    const meta = annotation.metadata || {}
    if (meta.kind === "composer") {
      return meta.composerKind === "signin"
        ? signInPrompt(() => this.setComposerAt(null))
        : commentComposer({
            onSave: (body) => this.createNewComment(body),
            onCancel: () => this.setComposerAt(null),
          })
    }

    const threadList = meta.threads || []

    return el("div", {}, [
      ...threadList.map((thread) =>
        threadBubble({
          thread,
          onReply: this.signedIn ? (t, body) => this.replyToThread(t, body) : null,
        })
      ),
    ])
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

  options() {
    return {
      theme: currentPierreTheme(),
      diffStyle: this.diffStyle,
      unsafeCSS: REVIEWS_DIFF_TYPOGRAPHY_CSS,
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

    if (shouldVirtualize({ rawDiff: this.rawDiff, fileDiff: this.fileDiff, diffStyle: this.diffStyle })) {
      if (this.tryRenderVirtualized(options, renderArgs)) return
    }

    this.instance = new Diffs.FileDiff(options)
    this.instance.render(renderArgs)
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
      this.container.replaceChildren()
      return false
    }
  }

  cleanUp(clear = true) {
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
