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
          {"> quoted\n- [x] done\n1. see [docs](https://x.test)", "quoted done see docs"}
        ] do
      assert LinkPreview.plain_text(markdown) == text, "for #{inspect(markdown)}"
    end
  end

  test "plain_text ignores literal placeholder characters in the text" do
    assert LinkPreview.plain_text("text \u{E000}0\u{E001} only") == "text 0 only"

    assert LinkPreview.plain_text("`a` then \u{E000}0\u{E001} and \u{E000}9\u{E001}") ==
             "a then 0 and 9"
  end

  test "plain_text stays fast on a body with thousands of code spans" do
    body = String.duplicate("x `a` ", 50_000)
    {microseconds, text} = :timer.tc(fn -> LinkPreview.plain_text(body) end)

    assert String.starts_with?(text, "x a x a")
    assert String.ends_with?(text, "…")
    assert microseconds < 500_000
  end
end
