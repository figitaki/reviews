export function applyStyles(el, styles) {
  Object.assign(el.style, styles)
  return el
}

export function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag)

  for (const [key, value] of Object.entries(attrs)) {
    if (value == null || value === false) continue

    if (key === "style") {
      applyStyles(node, value)
    } else if (key === "className") {
      node.className = value
    } else if (key === "dataset") {
      for (const [dataKey, dataValue] of Object.entries(value)) {
        node.dataset[dataKey] = dataValue
      }
    } else if (key.startsWith("on") && typeof value === "function") {
      node.addEventListener(key.slice(2).toLowerCase(), value)
    } else if (value === true) {
      node.setAttribute(key, "")
    } else {
      node.setAttribute(key, value)
    }
  }

  for (const child of [].concat(children)) {
    if (child == null) continue
    node.append(child instanceof Node ? child : document.createTextNode(String(child)))
  }

  return node
}

export function button(label, onClick, attrs = {}) {
  return el(
    "button",
    {
      type: "button",
      style: attrs.primary ? attrs.primaryStyle : attrs.style,
      onclick: onClick,
      "aria-label": attrs.ariaLabel,
      title: attrs.title,
    },
    label
  )
}
