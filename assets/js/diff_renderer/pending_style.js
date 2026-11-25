// The diff style a toolbar click asked for wins over the patched dataset
// until the server agrees (issue #235). Returns the style to show and the
// pending style still waiting for that reply, or null once it arrived.
export function resolveDiffStyle(serverStyle, pendingStyle) {
  if (!pendingStyle || pendingStyle === serverStyle) {
    return { style: serverStyle, pending: null }
  }
  return { style: pendingStyle, pending: pendingStyle }
}
