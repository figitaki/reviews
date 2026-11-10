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
    { oldStart: 1, newStart: 1, before: "# Title\nold", after: "# Title\nnew" },
    { oldStart: 20, newStart: 30, before: "later old", after: "later new" },
  ])
})

test("handles whole added and deleted documents and header-like content", () => {
  assert.deepEqual(markdownPatchExcerpts("@@ -0,0 +1,2 @@\n+# New\n+---\n"), [
    { oldStart: 0, newStart: 1, before: "", after: "# New\n---" },
  ])
  assert.equal(markdownPatchExcerpts("@@ -1,2 +0,0 @@\n-# Old\n----\n")[0].before, "# Old\n---")
  assert.deepEqual(markdownPatchExcerpts("Binary files differ"), [])
  assert.deepEqual(markdownPatchExcerpts(""), [])
  assert.equal(isMarkdown("docs/README.MD"), true)
  assert.equal(isMarkdown("src/file.js"), false)
  assert.equal(isMarkdown(undefined), false)
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
    for (const html of [renderMarkdown(excerpt.before), renderMarkdown(excerpt.after)]) {
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
  assert.match(previewNotice(1), /1 discussion is shown in Source\.$/)
  assert.match(previewNotice(3), /3 discussions are shown in Source\.$/)
})
