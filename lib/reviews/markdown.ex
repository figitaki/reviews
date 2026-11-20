defmodule Reviews.Markdown do
  @moduledoc """
  Server-side Markdown, parsed with MDEx (comrak) in the dialect the browser
  renders with markdown-it (`assets/js/lib/markdown.js`): CommonMark with
  tables, strikethrough and bare-URL links, and authored HTML never rendered
  as markup.

  Use `options/0` for any server-side parse or render, so every caller reads
  Markdown the same way.

  ## HTML

  `to_html/2` renders packet prose and comments. Both are untrusted:

    * Raw HTML is text, never markup.
    * Links go only where `allowed_link?/1` allows; a refused link keeps its text.
    * Images load only bundled `/images/<name>.svg`; any other image shows
      its alt text.

  The tree is cleaned first, then the HTML goes through an allowlist
  sanitizer (ammonia) as a second wall.
  """

  @options [
    extension: [table: true, strikethrough: true, autolink: true],
    render: [unsafe: false]
  ]

  @doc "MDEx options matching the browser's markdown-it setup."
  def options, do: @options

  @doc """
  Parses `markdown` into an `MDEx.Document`. A reference definition whose
  destination the browser refuses is not a definition there, so it is kept
  as text here too, and links that name it stay unresolved.
  """
  def parse(markdown) when is_binary(markdown) do
    document = MDEx.parse_document!(markdown, @options)

    case keep_refused_definitions(markdown, document) do
      ^markdown -> document
      escaped -> MDEx.parse_document!(escaped, @options)
    end
  end

  @definition ~r/^( {0,3})\[((?:[^\]\\]|\\.)+)\]:[ \t]*(.*)$/

  # Escapes the `[` of each refused definition outside code, which makes the
  # line a paragraph. The destination may sit on the next line.
  defp keep_refused_definitions(markdown, document) do
    code = code_lines(document)
    lines = String.split(markdown, "\n")

    lines
    |> Enum.with_index(1)
    |> Enum.map(fn {line, number} ->
      with false <- MapSet.member?(code, number),
           [_, indent, _label, rest] <- Regex.run(@definition, line),
           destination when is_binary(destination) <-
             destination(rest, Enum.at(lines, number)),
           false <- allowed_link?(destination) do
        indent <> "\\" <> String.trim_leading(line)
      else
        _ -> line
      end
    end)
    |> Enum.join("\n")
  end

  defp destination(rest, next_line) do
    source = if String.trim(rest) == "", do: next_line || "", else: rest

    case Regex.run(~r/^[ \t]*(?:<([^>\n]*)>|(\S+))/, source) do
      [_, angle] -> angle
      [_, "", bare] -> bare
      _ -> nil
    end
  end

  defp code_lines(%{nodes: nodes} = node) do
    own =
      case node do
        %module{sourcepos: %{start: {first, _}, end: {last, _}}}
        when module in [MDEx.CodeBlock, MDEx.HtmlBlock] ->
          MapSet.new(first..last//1)

        _ ->
          MapSet.new()
      end

    Enum.reduce(nodes, own, &MapSet.union(&2, code_lines(&1)))
  end

  defp code_lines(_node), do: MapSet.new()

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

  @change_class "review-markdown-change"
  @marked_tags ~w(p li pre table blockquote h1 h2 h3 h4 h5 h6 hr)

  @sanitize [
    tags:
      ~w(a blockquote br code del em h1 h2 h3 h4 h5 h6 hr img li ol p pre strong table tbody td th thead tr ul),
    tag_attributes: %{
      "a" => ~w(href),
      "img" => ~w(src alt),
      "code" => ~w(class),
      "ol" => ~w(start),
      "th" => ~w(align),
      "td" => ~w(align)
    },
    tag_attribute_values: Map.new(@marked_tags, &{&1, %{"class" => [@change_class]}}),
    generic_attributes: ~w(title),
    url_schemes: ~w(http https mailto),
    url_relative: :passthrough
  ]

  @doc """
  Sanitized HTML for `markdown`, cached by source (`Reviews.Markdown.Cache`).

  `changed_lines:` takes zero-based source line numbers. Each top-level
  block, or item of a top-level list, that covers one gets the
  `#{@change_class}` class, as the Markdown file preview marks changes.
  """
  def to_html(markdown, opts \\ [])
  def to_html(nil, _opts), do: ""

  # MDExNative is the Comrak binding under MDEx. Calling it with these
  # fixed options skips MDEx's per-call option validation, which costs
  # about 0.4 ms a document; the parse and render take about 0.02 ms.
  def to_html(markdown, opts) when is_binary(markdown) do
    changed = opts |> Keyword.get(:changed_lines, []) |> MapSet.new()

    if MapSet.size(changed) == 0 do
      Reviews.Markdown.Cache.fetch(markdown, fn ->
        markdown
        |> MDExNative.Comrak.parse_document!(@options)
        |> clean()
        |> MDExNative.Comrak.document_to_html!(@options ++ [sanitize: @sanitize])
      end)
    else
      options = put_in(@options, [:render, :sourcepos], true)
      document = markdown |> MDExNative.Comrak.parse_document!(options) |> clean()

      document
      |> MDExNative.Comrak.document_to_html!(options)
      |> mark_changes(changed_positions(document, changed))
      |> MDExNative.Ammonia.safe_html(sanitize: @sanitize)
    end
  end

  alias MDExNative.Comrak.{
    HtmlBlock,
    HtmlInline,
    Image,
    LineBreak,
    Link,
    SoftBreak,
    Text
  }

  defp clean(%{nodes: nodes} = node), do: %{node | nodes: Enum.flat_map(nodes, &clean_node/1)}

  # A rejected link keeps its text; a rejected image becomes its alt text.
  defp clean_node(%Link{url: url} = link) do
    if allowed_link?(url), do: [clean(link)], else: clean(link).nodes
  end

  defp clean_node(%Image{url: url} = image) do
    if bundled_image?(url), do: [image], else: [%Text{literal: plain_text(image)}]
  end

  # With `html: false` the browser never reads an HTML block, so its lines
  # are ordinary Markdown whose tags are text. A leading `<` is escaped on
  # every line outside code (where a backslash would show), so no line
  # starts a new HTML block, and the block reparses as Markdown. The
  # reparsed nodes move to the block's lines so `changed_lines:` finds them.
  defp clean_node(%HtmlBlock{literal: literal, sourcepos: %{start: {line, _}}}) do
    lines = String.split(literal, "\n")
    first = escape_lines(lines, &(&1 == 1))
    code = first |> MDExNative.Comrak.parse_document!(@options) |> native_code_lines()

    lines
    |> escape_lines(&(not MapSet.member?(code, &1)))
    |> MDExNative.Comrak.parse_document!(@options)
    |> clean()
    |> Map.fetch!(:nodes)
    |> Enum.map(&shift_lines(&1, line - 1))
  end

  defp clean_node(%HtmlInline{literal: literal}), do: [%Text{literal: literal}]
  defp clean_node(%{nodes: _} = node), do: [clean(node)]
  defp clean_node(node), do: [node]

  defp escape_lines(lines, escape?) do
    lines
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {text, number} ->
      if escape?.(number), do: String.replace(text, ~r/\A( {0,3})</, "\\1\\\\<"), else: text
    end)
  end

  defp native_code_lines(%MDExNative.Comrak.CodeBlock{
         sourcepos: %{start: {first, _}, end: {last, _}}
       }),
       do: MapSet.new(first..last//1)

  defp native_code_lines(%{nodes: nodes}),
    do: Enum.reduce(nodes, MapSet.new(), &MapSet.union(&2, native_code_lines(&1)))

  defp native_code_lines(_node), do: MapSet.new()

  defp shift_lines(%{sourcepos: %{start: {l1, c1}, end: {l2, c2}} = pos} = node, by) do
    node = %{node | sourcepos: %{pos | start: {l1 + by, c1}, end: {l2 + by, c2}}}

    case node do
      %{nodes: nodes} -> %{node | nodes: Enum.map(nodes, &shift_lines(&1, by))}
      node -> node
    end
  end

  defp shift_lines(node, _by), do: node

  # Only bundled SVG basenames: no hosts, subdirectories, traversal, escapes,
  # query strings or fragments, so packet images never make outside requests.
  defp bundled_image?(url),
    do: Regex.match?(~r/\A\/images\/[a-zA-Z0-9][a-zA-Z0-9_-]*\.svg\z/, url)

  defp plain_text(%{nodes: nodes}), do: Enum.map_join(nodes, &plain_text/1)
  defp plain_text(%{literal: literal}), do: literal
  defp plain_text(%SoftBreak{}), do: " "
  defp plain_text(%LineBreak{}), do: " "
  defp plain_text(_), do: ""

  # Source positions of the blocks a changed line falls in: top-level blocks
  # other than lists, and the items of top-level lists.
  defp changed_positions(document, changed) do
    document.nodes
    |> Enum.flat_map(fn
      %MDExNative.Comrak.List{nodes: items} -> items
      node -> [node]
    end)
    |> Enum.filter(fn %{sourcepos: %{start: {first, _}, end: {last, column}}} ->
      # An item that runs to a blank line ends at its column 0.
      last = if column == 0, do: last - 1, else: last
      Enum.any?((first - 1)..(last - 1)//1, &MapSet.member?(changed, &1))
    end)
    |> MapSet.new(fn %{sourcepos: %{start: {l1, c1}, end: {l2, c2}}} ->
      "#{l1}:#{c1}-#{l2}:#{c2}"
    end)
  end

  # Text escapes `<`, so only the renderer writes a tag; the sanitizer then
  # drops every data-sourcepos left.
  defp mark_changes(html, positions) do
    Regex.replace(~r/<([a-z0-9]+) data-sourcepos="([\d:-]+)"/, html, fn whole, tag, position ->
      if MapSet.member?(positions, position),
        do: ~s(<#{tag} class="#{@change_class}"),
        else: whole
    end)
  end
end
