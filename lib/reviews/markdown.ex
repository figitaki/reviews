defmodule Reviews.Markdown do
  @moduledoc """
  Server-side Markdown, parsed with MDEx (comrak) in the dialect the browser
  renders with markdown-it (`assets/js/lib/markdown.js`): CommonMark with
  tables, strikethrough and bare-URL links, and authored HTML never rendered
  as markup.

  Use `options/0` for any server-side parse or render, so every caller reads
  Markdown the same way.
  """

  @options [
    extension: [table: true, strikethrough: true, autolink: true],
    render: [unsafe: false]
  ]

  @doc "MDEx options matching the browser's markdown-it setup."
  def options, do: @options

  @doc "Parses `markdown` into an `MDEx.Document`."
  def parse(markdown) when is_binary(markdown), do: MDEx.parse_document!(markdown, @options)

  @doc """
  The text a reader sees, with Markdown removed: code as written, links as
  their text, images as their alt text and character references decoded.
  Authored HTML comes back as the literal text the browser shows for it
  (markdown-it runs with `html: false`), never as markup; callers escape the
  result like any other text. Blocks are separated by a space.
  """
  def to_text(markdown) when is_binary(markdown) do
    markdown |> parse() |> text() |> IO.iodata_to_binary()
  end

  defp text(%MDEx.Text{literal: literal}), do: literal
  defp text(%MDEx.Code{literal: literal}), do: literal
  defp text(%MDEx.CodeBlock{literal: literal}), do: [" ", literal, " "]
  defp text(%MDEx.SoftBreak{}), do: " "
  defp text(%MDEx.LineBreak{}), do: " "
  defp text(%MDEx.HtmlBlock{literal: literal}), do: [" ", literal, " "]
  defp text(%MDEx.HtmlInline{literal: literal}), do: literal

  defp text(%{nodes: nodes} = node) do
    children = Enum.map(nodes, &text/1)
    if inline?(node), do: children, else: [" ", children, " "]
  end

  # Nodes the options above never produce, such as front matter or math.
  defp text(_node), do: []

  defp inline?(%module{}),
    do:
      module in [
        MDEx.Emph,
        MDEx.Strong,
        MDEx.Strikethrough,
        MDEx.Link,
        MDEx.Image,
        MDEx.Escaped
      ]
end
