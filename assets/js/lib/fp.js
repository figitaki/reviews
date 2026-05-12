// Three pure helpers used by the diff renderer's data layer. Do not grow this
// file without a reason — see the patchset v1 brief.

// groupBy(items, keyFn) -> Map<key, T[]>
// Preserves the insertion order of first-seen keys.
export const groupBy = (items, keyFn) =>
  items.reduce((m, x) => {
    const k = keyFn(x)
    return m.set(k, [...(m.get(k) ?? []), x])
  }, new Map())

// keyUnion(...maps) -> Set<key>
// Returns the union of keys across the given Maps, preserving insertion order
// of the first map seen for each key.
export const keyUnion = (...maps) => {
  const out = new Set()
  for (const m of maps) for (const k of m.keys()) out.add(k)
  return out
}

// pluck(obj, keys[]) -> Partial<obj>
// Used to strip pushEvent payloads down to wire shape before zod parses them.
export const pluck = (obj, keys) =>
  Object.fromEntries(keys.filter((k) => k in obj).map((k) => [k, obj[k]]))
