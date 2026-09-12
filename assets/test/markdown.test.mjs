import { test } from 'node:test'
import assert from 'node:assert/strict'
import { isMarkdown, markdownPatchExcerpts, renderMarkdown } from '../js/lib/markdown.js'

test('renders document structure and inline formatting', () => {
  const html = renderMarkdown('# Title\n\n**bold** and *emphasis*\n\n1. First\n   - Nested\n\n> Quote\n\n| A | B |\n| - | - |\n| a | b |\n\n```js\nconst x = 1\n```')
  for (const tag of ['h1', 'strong', 'em', 'ol', 'ul', 'blockquote', 'table', 'pre', 'code']) {
    assert.match(html, new RegExp(`<${tag}[ >]`))
  }
})

test('escapes raw HTML and rejects executable links', () => {
  const html = renderMarkdown('<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\n[bad](javascript:alert(1))\n\n[good](https://example.com)')
  assert.doesNotMatch(html, /<script|<img|href="javascript:/)
  assert.match(html, /href="https:\/\/example.com"/)
  assert.match(renderMarkdown('```html\n<script>bad</script>\n```'), /&lt;script&gt;/)
})

test('reconstructs both sides without joining across omitted content', () => {
  const result = markdownPatchExcerpts('--- a/a.md\n+++ b/a.md\n@@ -1,2 +1,2 @@\n # Title\n-old\n+new\n@@ -20 +30 @@\n-later old\n+later new\n\\ No newline at end of file\n')
  assert.deepEqual(result, [
    { oldStart: 1, newStart: 1, before: '# Title\nold', after: '# Title\nnew' },
    { oldStart: 20, newStart: 30, before: 'later old', after: 'later new' },
  ])
})

test('handles whole added and deleted documents and header-like content', () => {
  assert.deepEqual(markdownPatchExcerpts('@@ -0,0 +1,2 @@\n+# New\n+---\n'), [
    { oldStart: 0, newStart: 1, before: '', after: '# New\n---' },
  ])
  assert.equal(markdownPatchExcerpts('@@ -1,2 +0,0 @@\n-# Old\n----\n')[0].before, '# Old\n---')
  assert.deepEqual(markdownPatchExcerpts('Binary files differ'), [])
  assert.equal(isMarkdown('docs/README.MD'), true)
  assert.equal(isMarkdown('src/file.js'), false)
})
