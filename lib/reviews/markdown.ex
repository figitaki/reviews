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
  # With `html: false` the browser reads an HTML block as ordinary Markdown
  # whose tags are text. Escaping the opening `<` makes the block a paragraph,
  # so its Markdown and character references read as on the page; a later
  # line that opens another block is shorter, so this ends.
  defp text(%MDEx.HtmlBlock{literal: literal}) do
    [" ", literal |> String.replace(~r/\A( {0,3})</, "\\1\\\\<") |> parse() |> text(), " "]
  end

  defp text(%MDEx.HtmlInline{literal: literal}), do: literal

  # A destination the browser refuses is not a link there: its source stays
  # visible as text, as `[text](url)`, `![alt](url)` or `<url>`.
  defp text(%module{url: url, nodes: nodes} = link) when module in [MDEx.Link, MDEx.Image] do
    children = Enum.map(nodes, &text/1)

    cond do
      allowed_link?(url) ->
        children

      autolink?(link) ->
        ["<", url, ">"]

      true ->
        [if(module == MDEx.Image, do: "![", else: "["), children, "](", url, title(link), ")"]
    end
  end

  defp text(%{nodes: nodes} = node) do
    children = Enum.map(nodes, &text/1)
    if inline?(node), do: children, else: [" ", children, " "]
  end

  # Nodes the options above never produce, such as front matter or math.
  defp text(_node), do: []

  defp title(%{title: ""}), do: ""
  defp title(%{title: title}), do: [~s( "), title, ~s(")]

  defp autolink?(%MDEx.Link{url: url, nodes: [%MDEx.Text{literal: text}]}),
    do: text in [url, String.replace_prefix(url, "mailto:", "")]

  defp autolink?(_), do: false

  @doc """
  Whether the browser accepts `url` as a link or image destination. Mirrors
  `markdown.validateLink` in `assets/js/lib/markdown.js`, which checks the
  percent-encoded URL: raw control characters and backslashes count as their
  encoded forms.
  """
  def allowed_link?(url) do
    not Regex.match?(~r/%(?:0[0-9a-f]|1[0-9a-f]|5c|7f)|[\x00-\x1f\x7f\\]/i, url) and
      not String.starts_with?(url, "//") and
      (Regex.match?(~r/^(?:https?:|mailto:)/i, url) or not Regex.match?(~r/^[^\/?#]*:/, url))
  end

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
