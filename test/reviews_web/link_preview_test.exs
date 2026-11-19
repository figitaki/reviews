defmodule ReviewsWeb.LinkPreviewTest do
  use ExUnit.Case, async: true

  alias ReviewsWeb.LinkPreview

  # Expected text is what a reader sees in the rendered comment.
  test "plain_text keeps code as written and drops Markdown from prose" do
    for {markdown, text} <- [
          {"Call `__init__` instead of `__new__`.", "Call __init__ instead of __new__."},
          {"Use ``a `b` c`` here", "Use a `b` c here"},
          {"`**not bold**` and `*not em*`", "**not bold** and *not em*"},
          {"```elixir\ndef __foo__, do: :ok\n# not a heading\n```\nAfter",
           "def __foo__, do: :ok # not a heading After"},
          {"~~~\nunclosed _fence_", "unclosed _fence_"},
          {"**Bold**, *italic*, _also italic_ and ~~gone~~",
           "Bold, italic, also italic and gone"},
          {"snake_case_name and qos_p256_key stay", "snake_case_name and qos_p256_key stay"},
          # Outside code, Markdown reads __dunder__ as bold, as the app renders it.
          {"__dunder__ outside code", "dunder outside code"},
          {"> quoted\n- [x] done\n1. see [docs](https://x.test) ![a cat](/c.png)",
           "quoted [x] done see docs a cat"},
          # Reference links read as their text; definitions are dropped.
          {"See [docs][ref].\n\n[ref]: https://example.com", "See docs."},
          {"[Docs][] and [guide], not [missing][nope]\n\n[docs]: /d\n[Guide]: /g 'Title'",
           "Docs and guide, not [missing][nope]"},
          {"`[a][r]` stays\n\n[r]: /x", "[a][r] stays"},
          # Indented code keeps its text, but cannot interrupt a paragraph.
          {"Before:\n\n    __init__(**kw)\n    _x_\n\nAfter **b**",
           "Before: __init__(**kw) _x_ After b"},
          {"para\n    __lazy__ continuation", "para lazy continuation"},
          # A fence closes only on the same character, at least as long.
          {"````\n```\n**literal**\n```\n````\nAfter *em*", "``` **literal** ``` After em"},
          {"```\n**a**\n~~~\n**b**\n```", "**a** ~~~ **b**"},
          # Only matched, unescaped delimiters are formatting.
          {"foo__bar__baz and a ** lone pair", "foo__bar__baz and a ** lone pair"},
          {"\\*literal\\* and \\_kept\\_ but *em*", "*literal* and _kept_ but em"},
          # Character references decode in prose; code keeps them as written.
          {"Tom &amp; Jerry &lt;3 &#65;&#x42; &hearts;", "Tom & Jerry <3 AB ♥"},
          {"`Tom &amp; Jerry` and\n\n```\n&lt;tag&gt;\n```", "Tom &amp; Jerry and &lt;tag&gt;"},
          # Authored HTML reads as the text the browser shows, never as markup.
          {"a <b>bold</b> word\n\n<div>\nblock\n</div>", "a <b>bold</b> word <div> block </div>"},
          {"| a | b |\n|---|---|\n| 1 | ~~2~~ |\n\nsee https://x.test",
           "a b 1 2 see https://x.test"}
        ] do
      assert LinkPreview.plain_text(markdown) == text, "for #{inspect(markdown)}"
    end
  end

  test "plain_text keeps private-use characters as written" do
    assert LinkPreview.plain_text("text \u{E000}0\u{E001} `a`") == "text \u{E000}0\u{E001} a"
  end

  test "plain_text stays fast on a body with thousands of code spans" do
    body = String.duplicate("x `a` ", 50_000)
    {microseconds, text} = :timer.tc(fn -> LinkPreview.plain_text(body) end)

    assert String.starts_with?(text, "x a x a")
    assert String.ends_with?(text, "…")
    assert microseconds < 500_000
  end
end
