// CodeViewRenderer — wraps one @pierre/diffs `CodeView` for the whole Changes
// view. CodeView is a self-contained virtualizer: it renders a single scroll
// container holding every file's diff and only paints what is visible, so all
// files can be expanded by default. Diff payloads are streamed in by the
// `CodeView` LiveView hook and appended via `addItems`.

import * as Diffs from "@pierre/diffs"

import { commentComposer, signInPrompt, threadBubble } from "./annotation_ui.js"
import { el } from "./dom.js"
import {
  annotationSideToSide,
  composerToAnchor,
  threadsToAnnotations,
} from "../lib/translate.js"

const TYPOGRAPHY_CSS = `
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

// A raw git-diff string -> a single FileDiffMetadata for the file, or null.
function parsePatch(rawDiff, filePath) {
  if (!rawDiff || typeof Diffs.parsePatchFiles !== "function") return null
  try {
    const parsed = Diffs.parsePatchFiles(rawDiff, filePath || "patch")
    const files = Array.isArray(parsed)
      ? parsed.flatMap((patch) => patch?.files || [])
      : []
    if (files.length === 0) return null
    return (
      files.find((diff) => diff?.name === filePath || diff?.prevName === filePath) ||
      files[0]
    )
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error("[CodeView] failed to parse patch:", filePath, err)
    return null
  }
}

function lineTextFromEvent(props) {
  return (props?.lineElement && props.lineElement.textContent) || ""
}

export class CodeViewRenderer {
  constructor({ container, signedIn, diffStyle, onCreateComment }) {
    this.container = container
    this.signedIn = signedIn
    this.diffStyle = diffStyle === "unified" ? "unified" : "split"
    this.onCreateComment = onCreateComment
    // file_path -> CodeViewDiffItem we last handed to CodeView
    this.itemsByPath = new Map()
    // file_path -> Thread[]
    this.threadsByPath = new Map()
    // { filePath, side, lineNumber, kind, ... } — at most one composer open
    this.composerAt = null
    this.codeView = null
  }

  setup() {
    this.codeView = new Diffs.CodeView(this.buildOptions())
    this.codeView.setup(this.container)
  }

  buildOptions() {
    return {
      theme: currentPierreTheme(),
      diffStyle: this.diffStyle,
      unsafeCSS: TYPOGRAPHY_CSS,
      stickyHeaders: true,
      renderAnnotation: (annotation) => this.renderAnnotation(annotation),
      onLineNumberClick: (props, context) =>
        this.handleLineNumberClick(props, context),
      onTokenClick: (props, context) => this.handleTokenClick(props, context),
    }
  }

  // --- Streaming -----------------------------------------------------------

  // rawItems: [{ file_path, raw_diff, threads }]
  addItems(rawItems) {
    if (!this.codeView) return
    const items = []
    for (const raw of rawItems || []) {
      const item = this.buildItem(raw)
      if (item) items.push(item)
    }
    if (items.length > 0) this.codeView.addItems(items)
  }

  buildItem(raw) {
    const filePath = raw?.file_path
    if (!filePath) return null

    const fileDiff = parsePatch(raw.raw_diff, filePath)
    if (!fileDiff) {
      // eslint-disable-next-line no-console
      console.warn("[CodeView] skipping unparseable diff for", filePath)
      return null
    }

    if (Array.isArray(raw.threads)) this.threadsByPath.set(filePath, raw.threads)

    const item = {
      id: filePath,
      type: "diff",
      fileDiff,
      annotations: this.annotationsFor(filePath),
      version: 1,
    }
    this.itemsByPath.set(filePath, item)
    return item
  }

  reset() {
    this.itemsByPath.clear()
    this.threadsByPath.clear()
    this.composerAt = null
    this.codeView?.reset()
  }

  // --- Threads / annotations ----------------------------------------------

  updateThreads(filePath, threads) {
    this.threadsByPath.set(filePath, threads || [])
    this.refreshItem(filePath)
  }

  annotationsFor(filePath) {
    const threads = this.threadsByPath.get(filePath) || []
    const real = threadsToAnnotations(threads).map((annotation) => ({
      ...annotation,
      metadata: { kind: "real", ...annotation.metadata },
    }))

    if (!this.composerAt || this.composerAt.filePath !== filePath) return real

    return [
      ...real,
      {
        side: this.composerAt.side,
        lineNumber: this.composerAt.lineNumber,
        metadata: {
          kind: "composer",
          composerKind: this.composerAt.kind,
        },
      },
    ]
  }

  // Re-publish one file's item with fresh annotations and a bumped version so
  // CodeView re-renders just that item.
  refreshItem(filePath) {
    const item = this.itemsByPath.get(filePath)
    if (!item || !this.codeView) return
    const updated = {
      ...item,
      annotations: this.annotationsFor(filePath),
      version: (item.version || 1) + 1,
    }
    this.itemsByPath.set(filePath, updated)
    this.codeView.updateItem(updated)
  }

  renderAnnotation(annotation) {
    const meta = annotation.metadata || {}

    if (meta.kind === "composer") {
      return meta.composerKind === "signin"
        ? signInPrompt(() => this.closeComposer())
        : commentComposer({
            onSave: (body) => this.createNewComment(body),
            onCancel: () => this.closeComposer(),
          })
    }

    const threadList = meta.threads || []
    return el(
      "div",
      {},
      threadList.map((thread) =>
        threadBubble({
          thread,
          onReply: this.signedIn
            ? (t, body) => this.replyToThread(t, body)
            : null,
        })
      )
    )
  }

  // --- Composer ------------------------------------------------------------

  openComposer(composerAt) {
    const previous = this.composerAt?.filePath
    this.composerAt = composerAt
    if (previous && previous !== composerAt.filePath) this.refreshItem(previous)
    this.refreshItem(composerAt.filePath)
  }

  closeComposer() {
    const filePath = this.composerAt?.filePath
    this.composerAt = null
    if (filePath) this.refreshItem(filePath)
  }

  createNewComment(body) {
    if (!this.composerAt) return
    const { filePath, side } = this.composerAt
    this.onCreateComment({
      file_path: filePath,
      side: annotationSideToSide(side),
      body,
      thread_anchor: composerToAnchor(this.composerAt),
      line_text: this.composerAt.lineText || "",
    })
    this.closeComposer()
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

  handleLineNumberClick(props, context) {
    const filePath = context?.item?.id
    const side = props?.annotationSide || props?.side
    const lineNumber = props?.lineNumber
    if (!filePath || !side || !lineNumber) return

    if (!this.signedIn) {
      this.openComposer({ kind: "signin", filePath, side, lineNumber })
      return
    }

    this.openComposer({
      kind: "line",
      filePath,
      side,
      lineNumber,
      lineText: lineTextFromEvent(props),
    })
  }

  handleTokenClick(props, context) {
    const filePath = context?.item?.id
    const side = props?.side
    const lineNumber = props?.lineNumber
    const tokenText = props?.tokenText || ""
    if (!filePath || !side || !lineNumber || tokenText.trim().length === 0) return

    if (!this.signedIn) {
      this.openComposer({ kind: "signin", filePath, side, lineNumber })
      return
    }

    const lineEl =
      (props?.tokenElement && props.tokenElement.closest("[data-line]")) || null
    this.openComposer({
      kind: "token",
      filePath,
      side,
      lineNumber,
      lineText: (lineEl && lineEl.textContent) || "",
      lineCharStart: props.lineCharStart,
      lineCharEnd: props.lineCharEnd,
      tokenText,
    })
  }

  // --- Options -------------------------------------------------------------

  setDiffStyle(diffStyle) {
    const next = diffStyle === "unified" ? "unified" : "split"
    if (this.diffStyle === next) return
    this.diffStyle = next
    this.codeView?.setOptions(this.buildOptions())
  }

  refreshTheme() {
    this.codeView?.setOptions(this.buildOptions())
  }

  scrollToFile(filePath) {
    if (!this.codeView || !this.itemsByPath.has(filePath)) return
    this.codeView.scrollTo({
      type: "item",
      id: filePath,
      align: "start",
      behavior: "instant",
    })
  }

  cleanUp() {
    try {
      this.codeView?.cleanUp()
    } finally {
      this.codeView = null
    }
  }
}
