// DiffRenderer — Phoenix LiveView hook that mounts a React island per file.
//
// SPIKE: this version swaps the hand-rolled renderer for `<PatchDiff>` from
// `@pierre/diffs/react`. Threads, drafts, composer, selection pill, and our
// own Shiki tokenizer are intentionally disabled in this spike — we're just
// confirming the library renders and themes correctly on one file before
// wiring lineAnnotations / renderAnnotation in the next step.
//
// The contract from the LiveView template is unchanged: each per-file
// <div phx-hook="DiffRenderer" phx-update="ignore"> carries a `data-raw-diff`
// attribute (the unified diff for the file). We mount a React root inside
// `this.el` and feed that string to `<PatchDiff patch={...} />`.

import React from "react"
import { createRoot } from "react-dom/client"
import { PatchDiff } from "@pierre/diffs/react"
// Note: `<PatchDiff>` transitively imports the side-effect module that
// registers the `<diffs-container>` custom element (via the underlying
// FileDiff component), so we don't need to import it explicitly here.

const DiffRenderer = {
  mounted() {
    const rawDiff = this.el.dataset.rawDiff || ""

    const root = createRoot(this.el)
    root.render(
      <PatchDiff
        patch={rawDiff}
        style={{ width: "100%" }}
      />
    )

    this._root = root
  },

  updated() {
    // We own the DOM (phx-update="ignore"). The server-pushed events that
    // refreshed threads/drafts in the previous design aren't wired in this
    // spike; the next step will reintroduce them via lineAnnotations.
  },

  destroyed() {
    this._root?.unmount()
    this._root = null
  },
}

export default DiffRenderer
