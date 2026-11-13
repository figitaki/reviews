import assert from "node:assert/strict"
import { test } from "node:test"
import { parsePatchFiles } from "@pierre/diffs"
import { isMarkdown, markdownPatchExcerpts, renderMarkdown } from "./markdown.js"
import { discussionCount, markdownPreviewState, previewNotice } from "../diff_renderer/markdown_preview.js"

test("renders packet lists, links, emphasis, bold and fenced code", () => {
  const html = renderMarkdown('- **Check** *this* [guide](/docs/guide)\n- `code`\n\n1. First\n2. Next\n\n```js\nconst x = "<tag>"\n```')
  for (const fragment of ["<ul>", "<ol>", "<li>", "<strong>Check</strong>", "<em>this</em>", '<a href="/docs/guide">guide</a>', "<code>code</code>", '<pre><code class="language-js">', "&lt;tag&gt;"]) {
    assert.ok(html.includes(fragment), fragment)
  }
  assert.equal(renderMarkdown(), "")
})

test("escapes raw HTML and code rather than creating executable elements", () => {
  const html = renderMarkdown('<script>alert(1)</script>\n\n<img src=x onerror=alert(1)>\n\n```html\n<iframe src="https://tracker.example"></iframe>\n```')
  assert.ok(html.includes("&lt;script&gt;"))
  assert.ok(html.includes("&lt;img"))
  assert.ok(html.includes("&lt;iframe"))
  assert.doesNotMatch(html, /<(script|img|iframe)\b/i)
})

test("rejects executable, encoded, custom and protocol-relative link schemes", () => {
  for (const url of ["javascript:alert%281%29", "JaVaScRiPt:alert%281%29", "javascript&#58;alert%281%29", "jav&#x61;script:alert%281%29", "vbscript:evil", "data:text/html,evil", "file:///etc/passwd", "ftp://example.com", "custom:evil", "//example.com"]) {
    assert.doesNotMatch(renderMarkdown(`[link](${url})`), /<a\b/, url)
  }
  for (const url of ["https://example.com/docs", "http://example.com", "mailto:reviewer@example.com", "/docs", "docs/guide", "#section"]) {
    assert.match(renderMarkdown(`[link](${url})`), /<a href=/, url)
  }
})

test("allows only bundled SVG basenames and escapes blocked image alt text", () => {
  assert.equal(renderMarkdown("![Flow](/images/demo-packet-flow.svg)"), '<p><img src="/images/demo-packet-flow.svg" alt="Flow"></p>\n')
  for (const url of ["https://tracker.example/pixel.svg", "//tracker.example/pixel.svg", "/pixel.svg", "/images/a.png", "/images/../secret.svg", "/images/nested/a.svg", "/images/%2e%2e/secret.svg", "/images/a.svg?q=secret", "/images/a.svg#fragment", "data:image/png;base64,AAAA"]) {
    const html = renderMarkdown(`![<secret> & text](${url})`)
    assert.doesNotMatch(html, /<img\b/, url)
    assert.ok(html.includes("&lt;secret&gt; &amp; text"), url)
  }
  assert.equal(renderMarkdown("![**alt**](/images/a.png)"), "<p>alt</p>\n")
})

test("renders document structure for Markdown previews", () => {
  const html = renderMarkdown("# Title\n\n**bold** and *emphasis*\n\n1. First\n   - Nested\n\n> Quote\n\n| A | B |\n| - | - |\n| a | b |\n\n```js\nconst x = 1\n```")
  for (const tag of ["h1", "strong", "em", "ol", "ul", "blockquote", "table", "pre", "code"]) {
    assert.match(html, new RegExp(`<${tag}[ >]`))
  }
})

test("reconstructs both sides without joining across omitted content", () => {
  const result = markdownPatchExcerpts("--- a/a.md\n+++ b/a.md\n@@ -1,2 +1,2 @@\n # Title\n-old\n+new\n@@ -20 +30 @@\n-later old\n+later new\n\\ No newline at end of file\n")
  assert.deepEqual(result, [
    { oldStart: 1, newStart: 1, before: "# Title\nold", after: "# Title\nnew", beforeChanges: [1], afterChanges: [1] },
    { oldStart: 20, newStart: 30, before: "later old", after: "later new", beforeChanges: [0], afterChanges: [0] },
  ])
})

test("handles whole added and deleted documents and header-like content", () => {
  assert.deepEqual(markdownPatchExcerpts("@@ -0,0 +1,2 @@\n+# New\n+---\n"), [
    { oldStart: 0, newStart: 1, before: "", after: "# New\n---", beforeChanges: [], afterChanges: [0, 1] },
  ])
  assert.equal(markdownPatchExcerpts("@@ -1,2 +0,0 @@\n-# Old\n----\n")[0].before, "# Old\n---")
  assert.deepEqual(markdownPatchExcerpts("Binary files differ"), [])
  assert.deepEqual(markdownPatchExcerpts(""), [])
  assert.equal(isMarkdown("docs/README.MD"), true)
  assert.equal(isMarkdown("src/file.js"), false)
  assert.equal(isMarkdown(undefined), false)
})

test("marks changed Markdown blocks without marking unchanged context", () => {
  const [excerpt, additions, deletions] = markdownPatchExcerpts([
    "@@ -10,16 +20,16 @@", " # Guide", " ", "-Old intro.", "+New intro.", " ",
    " - Keep", "-- Old item", "+- New item", " ", " | Column |", " | --- |",
    "-| old |", "+| new |", " ", " ```js", "-old()", "+new()", " ```", " ", " > Stable quote",
    "@@ -50 +60,2 @@", " Stable", "+Added",
    "@@ -80,2 +90 @@", " Stable", "-Removed",
  ].join("\n"))
  assert.deepEqual(excerpt.beforeChanges, [2, 5, 9, 12])
  assert.deepEqual(excerpt.afterChanges, [2, 5, 9, 12])
  const html = renderMarkdown(excerpt.after, excerpt.afterChanges)
  assert.match(html, /<h1>Guide<\/h1>/)
  assert.match(html, /<p class="review-markdown-change">New intro\.<\/p>/)
  assert.match(html, /<li>Keep<\/li>/)
  assert.match(html, /<li class="review-markdown-change">New item<\/li>/)
  assert.match(html, /<table class="review-markdown-change">/)
  assert.match(html, /<pre class="review-markdown-change"><code class="language-js">new\(\)/)
  assert.match(html, /<blockquote>\n<p>Stable quote<\/p>/)
  assert.doesNotMatch(renderMarkdown(additions.before, additions.beforeChanges), /review-markdown-change/)
  assert.match(renderMarkdown(additions.after, additions.afterChanges), /review-markdown-change/)
  assert.match(renderMarkdown(deletions.before, deletions.beforeChanges), /review-markdown-change/)
  assert.doesNotMatch(renderMarkdown(deletions.after, deletions.afterChanges), /review-markdown-change/)
  assert.equal(renderMarkdown("    code", [0]), '<pre class="review-markdown-change"><code>code\n</code></pre>\n')
})

// Markdown previews render lines from untrusted diffs. Every payload goes
// through the same path the Preview button uses: patch -> excerpt -> HTML.
test("previews of untrusted patches never produce executable markup", () => {
  const payloads = [
    "<script>alert(1)</script>",
    "<img src=x onerror=alert(1)>",
    "<svg onload=alert(1)><script>alert(1)</script></svg>",
    "<iframe srcdoc=\"<script>alert(1)</script>\"></iframe>",
    "<details open ontoggle=alert(1)>x</details>",
    "<a href=\"javascript:alert(1)\">x</a>",
    "<javascript:alert(1)>",
    "javascript:alert(1)",
    "[x](javascript:alert(1))",
    "[x](JaVaScRiPt:alert(1))",
    "[x](&#106;&#97;&#118;&#97;&#115;&#99;&#114;&#105;&#112;&#116;&#58;alert(1))",
    "[x](javascript&colon;alert(1))",
    "[x](%6Aavascript:alert(1))",
    "[x](<javascript:alert(1)>)",
    "[x](data:text/html,<script>alert(1)</script>)",
    "[x](vbscript:msgbox(1))",
    "[x][ref]\n\n[ref]: javascript:alert(1)",
    "![x](data:image/svg+xml,<svg onload=alert(1)>)",
    "![x](https://tracker.example/pixel.png)",
    "![x](/images/a.svg\" onerror=\"alert(1))",
    "[x](https://example.com\"onmouseover=\"alert(1))",
    "[x](https://example.com \"t\\\" onmouseover=\\\"alert(1)\")",
    "```js\" onclick=\"alert(1)\n<script>alert(1)</script>\n```",
    "```mermaid\ngraph TD; A[<img src=x onerror=alert(1)>]-->B\n```",
  ]
  for (const payload of payloads) {
    const lines = payload.split("\n")
    const patch = `@@ -1,${lines.length} +1,${lines.length} @@\n${lines.map(l => `-${l}`).join("\n")}\n${lines.map(l => `+${l}`).join("\n")}\n`
    const [excerpt] = markdownPatchExcerpts(patch)
    assert.equal(excerpt.after, payload)
    for (const html of [renderMarkdown(excerpt.before, excerpt.beforeChanges), renderMarkdown(excerpt.after, excerpt.afterChanges), renderMarkdown(excerpt.after, excerpt.afterChanges, { preview: true })]) {
      assert.doesNotMatch(html, /<(script|img|svg|iframe|details|object|embed)\b/i, payload)
      // Attribute values are quoted and escaped; look for handlers outside them.
      assert.doesNotMatch(html.replace(/"[^"]*"/g, '""'), /<[a-z][^>]*\son[a-z]+\s*=/i, payload)
      assert.doesNotMatch(html, /(href|src)="\s*(javascript|vbscript|data):/i, payload)
      assert.doesNotMatch(html, /(href|src)="https:\/\/tracker/i, payload)
    }
  }
})

test("the preview notice counts only discussions on the displayed side and hunks", () => {
  const [{ files: [{ hunks }] }] = parsePatchFiles([
    "diff --git a/a.md b/a.md", "--- a/a.md", "+++ b/a.md",
    "@@ -10,2 +20,3 @@", " context", "-old", "+new", "+added",
    "@@ -40 +50,0 @@", "-removed",
  ].join("\n") + "\n")
  const thread = (side, line) => ({ side, anchor: { line_number_hint: line } })
  const outside = [thread("old", 9), thread("old", 12), thread("new", 19),
    thread("new", 23), thread("old", 20), thread("new", 10), thread("new", 50)]
  assert.equal(discussionCount(outside, hunks), 0)
  assert.equal(discussionCount([...outside, thread("old", 11)], hunks), 1)
  assert.equal(discussionCount([thread("old", 10), thread("new", 22), thread("old", 40)], hunks), 3)
  assert.equal(discussionCount(), 0)
})

test("change lookup preserves exclusive block boundaries and unsorted input", () => {
  const changes = [6, 1, 4]
  assert.equal(renderMarkdown("First\n\nSecond\n\nThird\n\nFourth", changes),
    '<p>First</p>\n<p>Second</p>\n<p class="review-markdown-change">Third</p>\n<p class="review-markdown-change">Fourth</p>\n')
  assert.deepEqual(changes, [6, 1, 4])
})

test("ambiguous Markdown excerpts fall back instead of inventing structure", () => {
  for (const patch of [
    "@@ -10,7 +10,7 @@\n const a = 1\n const b = 2\n ```\n-Old prose after the fence.\n+New prose after the fence.\n \n ## Next heading\n More text",
    "@@ -20,3 +20,3 @@\n     continuation of a list item paragraph\n     - nested item\n-    - old nested\n+    - new nested",
    "@@ -30,3 +30,3 @@\n | a | b |\n-| c | d |\n+| c | e |\n | f | g |",
    "@@ -30,2 +30,2 @@\n a | b\n-c | d\n+c | e",
    "@@ -1,2 +1,2 @@\n ```js\n-old()\n+new()",
    "@@ -8,2 +8,2 @@\n ~~~~\n-old\n+new",
  ]) {
    const state = markdownPreviewState(patch)
    assert.match(state.reason, /Surrounding Markdown is missing/, patch)
    assert.equal(state.excerpts, undefined)
  }
  for (const patch of [
    "@@ -20,3 +20,3 @@\n # Heading\n-old prose\n+new prose\n More text",
    "@@ -20,3 +20,3 @@\n | A | B |\n | --- | --- |\n-| c | d |\n+| c | e |",
    "@@ -20,3 +20,3 @@\n A | B\n --- | ---\n-c | d\n+c | e",
    "@@ -1,3 +1,3 @@\n ```js\n-old()\n+new()\n ```",
  ]) assert.equal(markdownPreviewState(patch).reason, null, patch)
})

test("complete documents render without excerpt warnings, and large ones stay in Source", () => {
  const patch = "@@ -0,0 +1,3 @@\n+```js\n+hello()\n+```"
  const state = markdownPreviewState(patch, { type: "new", unifiedLineCount: 3 })
  assert.equal(state.complete, true)
  assert.equal(state.excerpts[0].after, "```js\nhello()\n```")
  assert.match(previewNotice(true, state), /Complete document/)
  assert.doesNotMatch(previewNotice(false, state), /excerpts|Source/i)
  assert.equal(markdownPreviewState(patch, { unifiedLineCount: 1499 }).reason, null)
  assert.match(markdownPreviewState(patch, { unifiedLineCount: 1500 }).reason, /Large/)
  assert.match(markdownPreviewState("é".repeat(100 * 1024)).reason, /Large/)
  assert.match(previewNotice(true, { complete: false }), /omitted context/)
})

test("preview headings fit the review outline and repository-relative links cannot navigate to review routes", () => {
  const html = renderMarkdown("## Title\n\n#### Child\n\n[setup](setup.md) [external](https://example.com)", [], { preview: true })
  assert.match(html, /role="heading" aria-level="4" data-markdown-heading="h2"/)
  assert.match(html, /role="heading" aria-level="5" data-markdown-heading="h4"/)
  assert.doesNotMatch(html, /<h[1-6]|href="setup.md"/)
  assert.match(html, /Repository-relative link/)
  assert.match(html, /target="_blank" rel="noopener noreferrer"/)
  assert.match(renderMarkdown("[setup](setup.md)"), /href="setup.md"/)
  assert.doesNotMatch(renderMarkdown("[x](/\\\\evil)"), /<a\b/)
})
