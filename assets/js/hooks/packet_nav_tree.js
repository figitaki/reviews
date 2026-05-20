import {FileTree} from "@pierre/trees"

const statText = stat => {
  if (!stat) return null

  const parts = []
  if (stat.additions > 0) parts.push(`+${stat.additions}`)
  if (stat.deletions > 0) parts.push(`-${stat.deletions}`)

  return parts.length > 0 ? parts.join(" ") : null
}

const statParts = stat => {
  if (!stat) return []

  const parts = []
  if (stat.additions > 0) parts.push({className: "review-packet-nav-stat-add", text: `+${stat.additions}`})
  if (stat.deletions > 0) parts.push({className: "review-packet-nav-stat-del", text: `-${stat.deletions}`})

  return parts
}

const treeStyles = `
  :host {
    --trees-bg-override: transparent;
    --trees-bg-muted-override: var(--review-panel-raised);
    --trees-border-color-override: var(--review-line);
    --trees-fg-override: var(--review-muted);
    --trees-fg-muted-override: var(--review-faint);
    --trees-accent-override: var(--review-blue, #7bb7ff);
    --trees-selected-bg-override: color-mix(in oklab, var(--review-text) 10%, transparent);
    --trees-selected-fg-override: var(--review-text);
    --trees-selected-focused-border-color-override: var(--review-blue, #7bb7ff);
    --trees-focus-ring-color-override: var(--review-blue, #7bb7ff);
    --trees-font-family-override: inherit;
    --trees-font-size-override: 12px;
    --trees-font-weight-semibold-override: 650;
    --trees-item-padding-x-override: 6px;
    --trees-item-margin-x-override: 0px;
    --trees-icon-width-override: 14px;
    --trees-level-gap-override: 12px;
    --trees-padding-inline-override: 0px;
    --trees-scrollbar-gutter-override: 6px;
  }

  button[data-type="item"] {
    border: 1px solid transparent;
    min-height: 28px;
  }

  button[data-type="item"]:hover {
    border-color: var(--review-line);
  }

  button[data-item-type="folder"] [data-item-section="content"] {
    color: var(--review-text);
    font-weight: 650;
  }

  [data-item-section="decoration"] {
    color: var(--review-muted);
    font-size: 11px;
    font-weight: 650;
  }

  .review-packet-nav-stat {
    display: inline-flex;
    align-items: baseline;
    gap: 5px;
    font-weight: 750;
    line-height: 1;
  }

  .review-packet-nav-stat-add {
    color: var(--review-add);
  }

  .review-packet-nav-stat-del {
    color: var(--review-del);
  }

  .review-packet-nav-title {
    display: inline-flex;
    min-width: 0;
    align-items: center;
    gap: 5px;
  }

  .review-packet-nav-label {
    min-width: 0;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .review-packet-nav-hunk-index {
    flex: 0 0 auto;
    min-width: 18px;
    border: 1px solid var(--review-line);
    border-radius: 999px;
    color: var(--review-muted);
    font-size: 10px;
    font-weight: 500;
    line-height: 1;
    padding: 3px 5px;
    text-align: center;
  }
`

const parseNav = el => {
  try {
    return JSON.parse(el.dataset.nav || "{}")
  } catch (_error) {
    return {}
  }
}

const sectionMap = sections => new Map((sections || []).map(section => [section.path, section]))
const pathSignature = paths => paths.join("\n")
const expandedSectionPaths = sections => (sections || [])
  .filter(section => section.expanded)
  .map(section => section.path)

const textLabel = text => {
  const label = document.createElement("span")
  label.className = "review-packet-nav-label"
  label.textContent = text
  return label
}

const basename = path => (path || "").replace(/\/$/, "").split("/").pop() || path

const PacketNavTree = {
  mounted() {
    this.pathsSignature = null
    this.suppressExpansionEvents = false
    this.selectionJump = null
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

    this.sections = sectionMap(nav.sections)
    this.targets = nav.targets || {}
    this.stats = nav.stats || {}

    if (paths.length === 0) {
      this.destroyTree()
      return
    }

    if (!this.tree) {
      this.mountTree(nav, paths, signature)
      return
    }

    if (signature !== this.pathsSignature) {
      this.pathsSignature = signature
      this.tree.resetPaths(paths, {initialExpandedPaths: expandedSectionPaths(nav.sections)})
    }

    this.syncSectionExpansion(nav.sections)
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

  mountTree(nav, paths, signature) {
    this.destroyTree()
    this.pathsSignature = signature

    this.tree = new FileTree({
      flattenEmptyDirectories: false,
      icons: {set: "minimal", colored: false},
      initialExpandedPaths: expandedSectionPaths(nav.sections),
      initialExpansion: "closed",
      itemHeight: 28,
      overscan: 6,
      paths,
      renderRowDecoration: ({item}) => {
        const text = statText(this.stats?.[item.path])
        return text ? {text, title: "Lines changed"} : null
      },
      unsafeCSS: treeStyles,
      onSelectionChange: selectedPaths => {
        const path = selectedPaths[selectedPaths.length - 1]
        this.selectionJump = {path, at: window.performance.now()}
        this.jumpToPath(path)
      },
    })

    this.unsubscribe = this.tree.subscribe(() => {
      this.scheduleStatDecorations()

      if (this.suppressExpansionEvents) return

      for (const [path, section] of this.sections || []) {
        const item = this.tree?.getItem(path)
        if (!item?.isDirectory?.()) continue

        const expanded = item.isExpanded()
        if (this.sectionExpansion.get(path) === expanded) continue

        this.sectionExpansion.set(path, expanded)
        this.pushEvent("toggle_packet_section", {section_index: section.section_index})
      }
    })

    this.tree.render({containerWrapper: this.el})
    this.attachTreeClick()
    this.syncSectionExpansion(nav.sections)
    this.scheduleStatDecorations()
  },

  attachTreeClick() {
    this.detachTreeClick?.()

    const root = this.tree?.getFileTreeContainer()?.shadowRoot
    if (!root) return

    const onClick = event => {
      const row = event.target?.closest?.('[data-type="item"]')
      const path = row?.getAttribute?.("data-item-path")
      const now = window.performance.now()

      if (this.selectionJump?.path === path && now - this.selectionJump.at < 50) return

      this.jumpToPath(path)
    }

    root.addEventListener("click", onClick)
    this.detachTreeClick = () => root.removeEventListener("click", onClick)
  },

  jumpToPath(path) {
    const target = this.targets?.[path]
    if (!target || target.type !== "hunk") return

    this.pushEvent("packet_nav_jump", {
      section_index: target.section_index,
      target_id: target.id,
    })
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
      const stat = this.stats?.[path]
      const parts = statParts(stat)

      const decoration = row.querySelector('[data-item-section="decoration"] > span')
      if (decoration && parts.length > 0) {
        const wrapper = document.createElement("span")
        wrapper.className = "review-packet-nav-stat"
        wrapper.title = "Lines changed"

        for (const part of parts) {
          const statNode = document.createElement("span")
          statNode.className = part.className
          statNode.textContent = part.text
          wrapper.appendChild(statNode)
        }

        decoration.replaceChildren(wrapper)
      } else if (decoration) {
        decoration.replaceChildren()
      }

      const content = row.querySelector('[data-item-section="content"]')
      if (!content) continue

      const rowType = row.getAttribute("data-item-type")
      const section = this.sections?.get(path)

      if (rowType === "folder") {
        content.replaceChildren(textLabel(section?.title || basename(path)))
        continue
      }

      if (rowType === "file" && stat) {
        const title = document.createElement("span")
        title.className = "review-packet-nav-title"
        title.appendChild(textLabel(stat.label || path.split("/").pop() || path))

        if (stat.hunk_index_label) {
          const hunkIndex = document.createElement("span")
          hunkIndex.className = "review-packet-nav-hunk-index"
          hunkIndex.textContent = stat.hunk_index_label
          title.appendChild(hunkIndex)
        }

        content.replaceChildren(title)
      } else if (rowType === "file") {
        content.replaceChildren(textLabel(basename(path)))
      }
    }
  },

  syncSectionExpansion(sections) {
    this.sectionExpansion = new Map(
      (sections || []).map(section => [section.path, section.expanded === true])
    )

    this.suppressExpansionEvents = true

    for (const section of sections || []) {
      const item = this.tree?.getItem(section.path)
      if (!item?.isDirectory?.()) continue

      const shouldExpand = section.expanded === true
      if (item.isExpanded() === shouldExpand) continue

      if (shouldExpand) {
        item.expand()
      } else {
        item.collapse()
      }
    }

    this.suppressExpansionEvents = false
  },
}

export default PacketNavTree
