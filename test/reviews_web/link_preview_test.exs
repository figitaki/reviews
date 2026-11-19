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
end
