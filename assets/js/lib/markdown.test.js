import assert from "node:assert/strict"
import { test } from "node:test"
import { isMarkdown, markdownPatchExcerpts, renderMarkdown } from "./markdown.js"
import { previewNotice } from "../diff_renderer/markdown_preview.js"

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
    for (const html of [renderMarkdown(excerpt.before, excerpt.beforeChanges), renderMarkdown(excerpt.after, excerpt.afterChanges)]) {
      assert.doesNotMatch(html, /<(script|img|svg|iframe|details|object|embed)\b/i, payload)
      // Attribute values are quoted and escaped; look for handlers outside them.
      assert.doesNotMatch(html.replace(/"[^"]*"/g, '""'), /<[a-z][^>]*\son[a-z]+\s*=/i, payload)
      assert.doesNotMatch(html, /(href|src)="\s*(javascript|vbscript|data):/i, payload)
      assert.doesNotMatch(html, /(href|src)="https:\/\/tracker/i, payload)
    }
  }
})

test("the preview notice points to Source for discussions", () => {
  assert.doesNotMatch(previewNotice(0), /discussion/)
  assert.match(previewNotice(1), /Source.*1 discussion\.$/)
  assert.match(previewNotice(3), /Source.*3 discussions\.$/)
})
