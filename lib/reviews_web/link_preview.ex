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
    # The page shows the description as plain text, not Markdown.
    description =
      case review.description |> to_string() |> one_line() do
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
    # Only a prefix is parsed: the result is cut near 300 characters anyway,
    # so a huge body costs little.
    markdown
    |> String.slice(0, @input_limit)
    |> Reviews.Markdown.to_text()
    |> one_line()
  end

  defp one_line(text) do
    text
    |> String.slice(0, @input_limit)
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate()
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
