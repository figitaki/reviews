defmodule Reviews.MarkdownTest do
  use ExUnit.Case, async: true

  alias Reviews.Markdown

  @tags ~w(a blockquote br code del em h1 h2 h3 h4 h5 h6 hr img li ol p pre strong table tbody td th thead tr ul)

  # Whatever the input, the parsed output holds only Markdown's own tags, no
  # event handler or style attributes, and no URL outside the allowed schemes.
  defp assert_inert(html) do
    nodes = html |> LazyHTML.from_fragment() |> LazyHTML.query("*")
    assert nodes |> LazyHTML.tag() |> Enum.reject(&(&1 in @tags)) == [], html

    for {name, value} <- nodes |> LazyHTML.attributes() |> List.flatten() do
      refute name =~ ~r/^on|^style$|^id$|^name$/i, html

      if name in ["href", "src"],
        do:
          refute(
            value =~ ~r/^\s*[a-z][a-z0-9+.-]*:/i and not (value =~ ~r/^(https?|mailto):/i),
            html
          )
    end

    html
  end

  defp links(html), do: Regex.scan(~r/<a\b[^>]*>/, html) |> List.flatten()
  defp images(html), do: Regex.scan(~r/<img\b[^>]*>/, html) |> List.flatten()

  test "renders packet and comment Markdown" do
    html =
      Markdown.to_html("""
      ### Title

      **bold** *em* ~~gone~~ `code` [guide](/docs/guide)

      - one
        1. nested

      > quote

      | A | B |
      | :- | -: |
      | a | b |

      ```js
      const x = "<tag>"
      ```
      """)

    for fragment <- [
          "<h3>Title</h3>",
          "<strong>bold</strong>",
          "<em>em</em>",
          "<del>gone</del>",
          "<code>code</code>",
          ~s(<a href="/docs/guide">guide</a>),
          "<ul>\n<li>one\n<ol>\n<li>nested</li>",
          "<blockquote>\n<p>quote</p>",
          ~s(<th align="left">A</th>),
          ~s(<td align="right">b</td>),
          ~s(<pre><code class="language-js">const x = "&lt;tag&gt;")
        ] do
      assert html =~ fragment
    end

    assert Markdown.to_html("") == ""
    assert Markdown.to_html(nil) == ""
  end

  test "shows raw HTML as text" do
    for source <- [
          "<script>alert(1)</script>",
          "text <script>alert(1)</script> more",
          "<img src=x onerror=alert(1)>",
          "a <b onclick=\"alert(1)\">b</b> <span onmouseover=alert(1)>c</span>",
          "<svg onload=alert(1)><circle/></svg>",
          "<iframe src=\"https://tracker.example\"></iframe>",
          "<style>body{display:none}</style>",
          "<a href=\"javascript:alert(1)\">x</a>",
          "<div>\n*inside*\n</div>",
          "<!-- comment --> <![CDATA[x]]>",
          "```html\n<iframe src=\"https://tracker.example\"></iframe>\n```"
        ] do
      html = source |> Markdown.to_html() |> assert_inert()
      assert html =~ "&lt;", source
      refute html =~ ~r/<(b|span|div|a)\s/, source
    end

    assert Markdown.to_html("<script>alert(1)</script>") ==
             "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>\n"
  end

  test "keeps HTML entities as text, never markup" do
    for {source, text} <- [
          {"&lt;script&gt;alert(1)&lt;/script&gt;", "&lt;script&gt;alert(1)&lt;/script&gt;"},
          {"&#60;img src=x onerror=alert(1)&#62;", "&lt;img src=x onerror=alert(1)&gt;"},
          {"&#x3C;b onclick=x&#x3E;", "&lt;b onclick=x&gt;"},
          {"Tom &amp; Jerry", "Tom &amp; Jerry"}
        ] do
      assert source |> Markdown.to_html() |> assert_inert() == "<p>#{text}</p>\n"
    end

    # A quote in a link title cannot end the attribute and start another.
    html = Markdown.to_html(~s|[x](https://ok.example "a&quot; onmouseover=&quot;alert(1)")|)
    assert_inert(html)

    assert ["a\" onmouseover=\"alert(1)"] ==
             html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("a")
             |> LazyHTML.attribute("title")
  end

  test "links only to http, https, mailto and relative URLs" do
    for url <- [
          "javascript:alert%281%29",
          "JaVaScRiPt:alert%281%29",
          "javascript&#58;alert%281%29",
          "jav&#x61;script:alert%281%29",
          "&#106;avascript:alert(1)",
          "java&#9;script:alert(1)",
          "java&#10;script:alert(1)",
          " javascript:alert(1)",
          "vbscript:evil",
          "data:text/html,evil",
          "data:text/html;base64,PHNjcmlwdD4=",
          "file:///etc/passwd",
          "ftp://example.com",
          "custom:evil",
          "//example.com",
          "/\\\\evil",
          "/%5Cevil",
          "https:%2F%2Fexample.com%0a",
          "/x%7f",
          "<a\\b>"
        ] do
      html = "[link](#{url})" |> Markdown.to_html() |> assert_inert()
      assert links(html) == [], url
    end

    # Autolinks and reference definitions go through the same check.
    for source <- [
          "<javascript:alert(1)>",
          "<JAVASCRIPT:alert(1)>",
          "[x][r]\n\n[r]: javascript:alert(1)",
          "[x][r]\n\n[r]: //example.com"
        ] do
      assert source |> Markdown.to_html() |> assert_inert() |> links() == [], source
    end

    for url <- [
          "https://example.com/docs",
          "http://example.com",
          "mailto:reviewer@example.com",
          "/docs",
          "docs/guide",
          "#section",
          "?tab=diff"
        ] do
      assert ["<a href=\"#{url}\">"] == "[link](#{url})" |> Markdown.to_html() |> links(), url
    end

    # A rejected link keeps its text.
    assert Markdown.to_html("[**read** this](javascript:x)") ==
             "<p><strong>read</strong> this</p>\n"

    # Bare www. addresses become links (comrak autolink); markdown-it's
    # linkify left them as text. Kept on purpose.
    assert links(Markdown.to_html("see www.example.com and <https://example.com>")) == [
             ~s(<a href="http://www.example.com">),
             ~s(<a href="https://example.com">)
           ]
  end

  test "loads only bundled SVG images and shows others as escaped alt text" do
    assert Markdown.to_html("![Flow](/images/demo-packet-flow.svg)") ==
             ~s(<p><img src="/images/demo-packet-flow.svg" alt="Flow"></p>\n)

    for url <- [
          "https://tracker.example/pixel.svg",
          "http://tracker.example/pixel.svg",
          "//tracker.example/pixel.svg",
          "/pixel.svg",
          "/images/a.png",
          "/images/../secret.svg",
          "/images/nested/a.svg",
          "/images/%2e%2e/secret.svg",
          "/images/a.svg?q=secret",
          "/images/a.svg#fragment",
          "/images/.svg",
          "data:image/png;base64,AAAA",
          "data:image/svg+xml,%3Csvg%20onload=alert(1)%3E",
          "javascript:alert(1)"
        ] do
      html = "![<secret> & text](#{url})" |> Markdown.to_html() |> assert_inert()
      assert images(html) == [], url
      assert html == "<p>&lt;secret&gt; &amp; text</p>\n", url
    end

    assert Markdown.to_html("![**alt**](/images/a.png)") == "<p>alt</p>\n"

    # Reference images and images inside links follow the same rule.
    assert images(Markdown.to_html("![x][r]\n\n[r]: https://tracker.example/p.svg")) == []

    assert Markdown.to_html("[![x](https://tracker.example/p.svg)](https://ok.example)") ==
             ~s(<p><a href="https://ok.example">x</a></p>\n)
  end

  test "marks changed blocks, code blocks and top-level list items" do
    assert Markdown.to_html("First\n\nSecond\n\nThird\n\nFourth", changed_lines: [6, 1, 4]) ==
             ~s(<p>First</p>\n<p>Second</p>\n<p class="review-markdown-change">Third</p>\n<p class="review-markdown-change">Fourth</p>\n)

    assert Markdown.to_html("    code", changed_lines: [0]) ==
             ~s(<pre class="review-markdown-change"><code>code\n</code></pre>\n)

    html = Markdown.to_html("- a\n- b\n  - nested\n\n```js\nx\n```", changed_lines: [2, 5])
    assert html =~ ~s(<li>a</li>\n<li class="review-markdown-change">b\n<ul>\n<li>nested</li>)
    assert html =~ ~s(<pre class="review-markdown-change"><code class="language-js">x)
    refute html =~ ~s(<ul class=)

    # Source text cannot place the marker or other attributes itself.
    html = Markdown.to_html(~s(a data-sourcepos="1:1-1:1" <b onclick=x>), changed_lines: [0])
    assert_inert(html)

    assert html ==
             ~s(<p class="review-markdown-change">a data-sourcepos="1:1-1:1" &lt;b onclick=x&gt;</p>\n)
  end
end
