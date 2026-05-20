import {FileTree} from "@pierre/trees"

const treeStyles = `
  :host {
    --trees-bg-override: var(--review-panel);
    --trees-bg-muted-override: var(--review-panel-raised);
    --trees-border-color-override: var(--review-line);
    --trees-fg-override: var(--review-muted);
    --trees-fg-muted-override: var(--review-faint);
    --trees-accent-override: var(--review-blue, #7bb7ff);
    --trees-selected-bg-override: transparent;
    --trees-selected-fg-override: var(--review-muted);
    --trees-selected-focused-border-color-override: transparent;
    --trees-focus-ring-color-override: var(--review-blue, #7bb7ff);
    --trees-font-family-override: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    --trees-font-size-override: 12px;
    --trees-font-weight-semibold-override: 650;
    --trees-item-padding-x-override: 8px;
    --trees-item-margin-x-override: 0px;
    --trees-icon-width-override: 14px;
    --trees-level-gap-override: 12px;
    --trees-padding-inline-override: 6px;
    --trees-scrollbar-gutter-override: 6px;
  }

  button[data-type="item"] {
    border: 1px solid transparent;
    box-sizing: border-box;
    min-height: 30px;
    width: 100%;
  }

  [data-item-section="content"] {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  button[data-type="item"]:hover {
    border-color: var(--review-line);
  }

  button[data-type="item"][aria-selected="true"] {
    background: transparent;
  }

  button[data-item-type="folder"] [data-item-section="content"] {
    color: var(--review-text);
    font-weight: 650;
  }

  [data-item-section="decoration"] {
    color: var(--review-muted);
    flex: 0 0 74px;
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    font-size: 12px;
    font-weight: 750;
    justify-content: flex-end;
    margin-left: auto;
    min-width: 74px;
  }

  .rev-file-tree-stat {
    display: inline-flex;
    align-items: baseline;
    gap: 5px;
    justify-content: flex-end;
    line-height: 1;
    width: 74px;
  }

  .rev-file-tree-stat-add {
    color: var(--review-add);
  }

  .rev-file-tree-stat-del {
    color: var(--review-del);
  }
`

const parseNav = el => {
  try {
    return JSON.parse(el.dataset.nav || "{}")
  } catch (_error) {
    return {}
  }
}

const pathSignature = paths => paths.join("\n")

const statText = stat => {
  if (!stat) return null

  return `+${stat.additions || 0} -${stat.deletions || 0}`
}

const statParts = stat => {
  if (!stat) return []

  return [
    {className: "rev-file-tree-stat-add", text: `+${stat.additions || 0}`},
    {className: "rev-file-tree-stat-del", text: `-${stat.deletions || 0}`},
  ]
}

const parentPaths = path => {
  const parts = (path || "").split("/").filter(Boolean)
  const parents = []

  for (let index = 1; index < parts.length; index += 1) {
    parents.push(parts.slice(0, index).join("/"))
  }

  return parents
}

const directoryPaths = paths => [...new Set(paths.flatMap(parentPaths))]

const aggregateStats = (paths, fileStats) => {
  const stats = {...fileStats}

  for (const path of paths) {
    const stat = fileStats[path]
    if (!stat) continue

    for (const parent of parentPaths(path)) {
      stats[parent] = {
        additions: (stats[parent]?.additions || 0) + (stat.additions || 0),
        deletions: (stats[parent]?.deletions || 0) + (stat.deletions || 0),
      }
    }
  }

  return stats
}

const updateHash = id => {
  if (!id) return
  window.history.replaceState(null, "", `#${encodeURIComponent(id)}`)
}

const ChangesFileTree = {
  mounted() {
    this.pathsSignature = null
    this.updateTree()
  },

  updated() {
    this.updateTree()
    this.scheduleStatDecorations()
  },

  destroyed() {
    if (this.statFrame) window.cancelAnimationFrame(this.statFrame)
    this.statFrame = null
    this.detachTreeClick?.()
    this.detachTreeClick = null
    this.unsubscribe?.()
    this.unsubscribe = null
    this.tree?.cleanUp()
    this.tree = null
  },

  updateTree() {
    const nav = parseNav(this.el)
    const paths = nav.paths || []
    const signature = pathSignature(paths)

    this.targets = nav.targets || {}
    this.stats = aggregateStats(paths, nav.stats || {})
    this.el.style.setProperty("--rev-file-tree-rows", Math.max(1, nav.row_count || paths.length))

    if (paths.length === 0) {
      this.destroyTree()
      return
    }

    if (!this.tree) {
      this.mountTree(paths, signature)
      return
    }

    if (signature !== this.pathsSignature) {
      this.pathsSignature = signature
      this.tree.resetPaths(paths, {initialExpandedPaths: directoryPaths(paths)})
    }

    this.scheduleStatDecorations()
  },

  destroyTree() {
    if (this.statFrame) window.cancelAnimationFrame(this.statFrame)
    this.statFrame = null
    this.detachTreeClick?.()
    this.detachTreeClick = null
    this.unsubscribe?.()
    this.unsubscribe = null
    this.tree?.cleanUp()
    this.tree = null
    this.pathsSignature = null
    this.el.replaceChildren()
  },

  mountTree(paths, signature) {
    this.destroyTree()
    this.pathsSignature = signature

    this.tree = new FileTree({
      flattenEmptyDirectories: false,
      icons: {set: "minimal", colored: false},
      initialExpandedPaths: directoryPaths(paths),
      initialExpansion: "closed",
      itemHeight: 30,
      overscan: 8,
      paths,
      renderRowDecoration: ({item}) => {
        const text = statText(this.stats?.[item.path])
        return text ? {text, title: "Lines changed"} : null
      },
      unsafeCSS: treeStyles,
    })

    this.unsubscribe = this.tree.subscribe(() => {
      this.scheduleStatDecorations()
    })

    this.tree.render({containerWrapper: this.el})
    this.attachTreeClick()
    this.scheduleStatDecorations()
  },

  attachTreeClick() {
    this.detachTreeClick?.()

    const root = this.tree?.getFileTreeContainer()?.shadowRoot
    if (!root) return

    const onPointerDown = event => {
      if (event.button !== 0) return
      if (!event.target?.closest?.('[data-type="item"]')) return

      event.preventDefault()
    }

    const onClick = event => {
      const row = event.target?.closest?.('[data-type="item"]')
      const path = row?.getAttribute?.("data-item-path")
      if (!path) return

      event.preventDefault()
      event.stopImmediatePropagation()

      if (row.getAttribute("data-item-type") === "folder") {
        this.tree?.getItem(path)?.toggle?.()
        return
      }

      this.scrollToPath(path)
    }

    root.addEventListener("pointerdown", onPointerDown, true)
    root.addEventListener("click", onClick, true)
    this.detachTreeClick = () => {
      root.removeEventListener("pointerdown", onPointerDown, true)
      root.removeEventListener("click", onClick, true)
    }
  },

  scrollToPath(path) {
    const target = this.targets?.[path]
    const targetEl = target?.id ? document.getElementById(target.id) : null
    if (!targetEl) return

    targetEl.scrollIntoView({block: "start"})
    updateHash(target.id)
  },

  scheduleStatDecorations() {
    if (this.statFrame) window.cancelAnimationFrame(this.statFrame)

    this.statFrame = window.requestAnimationFrame(() => {
      this.statFrame = null
      this.applyStatDecorations()
    })
  },

  applyStatDecorations() {
    const root = this.tree?.getFileTreeContainer()?.shadowRoot
    if (!root) return

    for (const row of root.querySelectorAll('[data-type="item"]')) {
      const path = row.getAttribute("data-item-path")
      const parts = statParts(this.stats?.[path])
      const decoration = row.querySelector('[data-item-section="decoration"] > span')

      if (!decoration) continue

      if (parts.length === 0) {
        decoration.replaceChildren()
        continue
      }

      const wrapper = document.createElement("span")
      wrapper.className = "rev-file-tree-stat"
      wrapper.title = "Lines changed"

      for (const part of parts) {
        const statNode = document.createElement("span")
        statNode.className = part.className
        statNode.textContent = part.text
        wrapper.appendChild(statNode)
      }

      decoration.replaceChildren(wrapper)
    }
  },
}

export default ChangesFileTree
