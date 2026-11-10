import assert from "node:assert/strict"
import { test } from "node:test"
import { renderMarkdown } from "./markdown.js"

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
