defmodule ReviewsWeb.LinkPreview do
  @moduledoc """
  Open Graph and Twitter card tags for review links, so Slack, iMessage,
  Discord and similar unfurlers can show a preview.

  A link naming a comment (`?thread=…&comment=…`, or just `?thread=…` for its
  first comment) previews that comment; any other link previews the review.
  Built from data the review page has already loaded, so it adds no query.
  Values are plain text; the root layout escapes them.
  """

  @site_name "Reviews"
  @description_limit 300
  @input_limit 4000

  @doc "Preview tags for `review`, or for the comment the params name on it."
  def build(review, threads, params, url) do
    case find_comment(threads, params["thread"], params["comment"]) do
      {thread, comment} -> comment_preview(review, thread, comment, url)
      nil -> review_preview(review, url)
    end
  end

  defp review_preview(review, url) do
    description =
      case plain_text(review.description) do
        "" -> "Code review by #{handle(review.author)}"
        text -> text
      end

    %{title: review.title, description: description, url: url, labels: []}
  end

  defp comment_preview(review, thread, comment, url) do
    %{
      title: "#{handle(comment.author)} commented on #{location(thread)}",
      description: plain_text(comment.body),
      url: url,
      labels: [{"Review", review.title}]
    }
  end

  defp find_comment(_threads, thread_id, _comment_id) when thread_id in [nil, ""], do: nil

  defp find_comment(threads, thread_id, comment_id) do
    with %{} = thread <- Enum.find(threads, &(to_string(&1.id) == thread_id)),
         %{} = comment <- pick_comment(thread.comments || [], comment_id) do
      {thread, comment}
    else
      _ -> nil
    end
  end

  defp pick_comment(comments, id) when id in [nil, ""], do: List.first(comments)
  defp pick_comment(comments, id), do: Enum.find(comments, &(to_string(&1.id) == id))

  # "line +9 in lib/foo.ex", like the thread header in the diff. An outdated
  # thread has no anchor on this revision, so it names the line it began on.
  defp location(thread) do
    anchor = Map.get(thread, :anchor) || Map.get(thread, :original_anchor) || %{}
    sign = if thread.side == "old", do: "-", else: "+"

    case anchor["line_number_hint"] do
      line when is_integer(line) -> "line #{sign}#{line} in #{thread.file_path}"
      _ -> thread.file_path
    end
  end

  defp handle(%{handle: handle}) when is_binary(handle), do: handle
  defp handle(_), do: "someone"

  @doc """
  Markdown reduced to one line of plain text, cut at a word near
  #{@description_limit} characters.
  """
  def plain_text(nil), do: ""

  def plain_text(markdown) do
    # Code keeps its text as written, so `__init__` stays `__init__`. Each
    # code block or span is set aside as a placeholder while the prose loses
    # its Markdown, then put back. Only a prefix is read, since the result is
    # cut near 300 characters anyway. The marker characters
    # are private-use and never shown, so literal ones are dropped and only
    # placeholders made here are put back.
    {prose, code} =
      markdown
      |> String.slice(0, @input_limit)
      |> String.replace(["\u{E000}", "\u{E001}"], "")
      |> set_aside_code()

    prose
    |> String.replace(~r/!\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/, "\\1")
    |> resolve_references()
    |> String.replace(~r/^\s{0,3}(\#{1,6}|>+|[-*+]\s+\[[ xX]\]|[-*+]|\d+[.)])\s+/m, "")
    |> String.replace(~r/(\*\*|__|~~)/, "")
    |> String.replace(~r/(?<![\w*])[*_](?=\S)(.+?)(?<=\S)[*_](?![\w*])/u, "\\1")
    |> then(
      &Regex.replace(~r/\x{E000}(\d+)\x{E001}/u, &1, fn _, i ->
        Map.fetch!(code, String.to_integer(i))
      end)
    )
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate()
  end

  # `[text][ref]`, `[text][]` and `[ref]` read as their text when `ref` is
  # defined, and definition lines (`[ref]: url`) are dropped, as the
  # renderer does. Undefined references stay as written, as they render.
  @reference_definition ~r/^ {0,3}\[([^\]]+)\]:[ \t]*\S.*$/m

  defp resolve_references(prose) do
    labels =
      @reference_definition
      |> Regex.scan(prose)
      |> MapSet.new(fn [_, label] -> reference_label(label) end)

    defined? = &MapSet.member?(labels, reference_label(&1))

    prose = String.replace(prose, @reference_definition, "")

    prose =
      Regex.replace(~r/\[([^\]]+)\]\[([^\]]*)\]/, prose, fn whole, text, ref ->
        if defined?.(if ref == "", do: text, else: ref), do: text, else: whole
      end)

    Regex.replace(~r/\[([^\]]+)\](?![\[(])/, prose, fn whole, text ->
      if defined?.(text), do: text, else: whole
    end)
  end

  defp reference_label(label),
    do: label |> String.downcase() |> String.replace(~r/\s+/u, " ") |> String.trim()

  # Code blocks keep their contents without fences or indentation, and inline
  # spans without their backticks. A fence closes only on a line of the same
  # character at least as long as the one that opened it; an indented block
  # cannot interrupt a paragraph.
  defp set_aside_code(markdown) do
    {lines, code} = code_blocks(String.split(markdown, "\n"), :blank, [], %{})
    code_spans(lines |> Enum.reverse() |> Enum.join("\n"), code)
  end

  defp code_blocks([], _previous, lines, code), do: {lines, code}

  defp code_blocks([line | rest], previous, lines, code) do
    cond do
      fence = opening_fence(line) ->
        {body, rest} = Enum.split_while(rest, &(not closing_fence?(&1, fence)))
        {lines, code} = put_code(lines, code, " #{Enum.join(body, "\n")} ")
        code_blocks(Enum.drop(rest, 1), :blank, lines, code)

      previous == :blank and indented?(line) ->
        {body, rest} = Enum.split_while([line | rest], &(indented?(&1) or blank?(&1)))
        body = Enum.map_join(body, "\n", &String.replace(&1, ~r/^( {4}|\t)/, ""))
        {lines, code} = put_code(lines, code, " #{body} ")
        code_blocks(rest, :blank, lines, code)

      blank?(line) ->
        code_blocks(rest, :blank, [line | lines], code)

      true ->
        code_blocks(rest, :text, [line | lines], code)
    end
  end

  defp opening_fence(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})(.*)$/, line) do
      ["", _, _] -> nil
      [_, "`" <> _ = run, info] -> if String.contains?(info, "`"), do: nil, else: run
      [_, run, _info] -> run
      nil -> nil
    end
  end

  defp closing_fence?(line, run) do
    mark = Regex.escape(String.first(run))
    Regex.match?(~r/^ {0,3}#{mark}{#{byte_size(run)},}[ \t]*$/, line)
  end

  defp indented?(line), do: String.starts_with?(line, ["    ", "\t"]) and not blank?(line)
  defp blank?(line), do: String.trim(line) == ""

  @code_span ~r/(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)/su

  defp code_spans(prose, code) do
    {prose, code} =
      @code_span
      |> Regex.split(prose, include_captures: true)
      |> Enum.reduce({[], code}, fn part, {prose, code} ->
        case Regex.run(@code_span, part) do
          [^part, _run, body] -> put_code(prose, code, String.trim(body))
          _ -> {[part | prose], code}
        end
      end)

    {prose |> Enum.reverse() |> IO.iodata_to_binary(), code}
  end

  # Block code is padded with spaces so it never joins the prose beside it.
  defp put_code(parts, code, text) do
    index = map_size(code)
    {["\u{E000}#{index}\u{E001}" | parts], Map.put(code, index, text)}
  end

  defp truncate(text) do
    if String.length(text) <= @description_limit do
      text
    else
      cut = String.slice(text, 0, @description_limit)

      cut =
        case Regex.run(~r/^(.*\S)\s+\S*$/su, cut) do
          [_, words] when byte_size(words) > div(byte_size(cut), 2) -> words
          _ -> cut
        end

      String.trim_trailing(cut, ".") <> "…"
    end
  end

  def site_name, do: @site_name
end
