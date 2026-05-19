defmodule Reviews.DemoReview do
  @moduledoc """
  Seeds the bundled review-packet demo from `priv/examples`.
  """

  alias Reviews.Accounts
  alias Reviews.Repo
  alias Reviews.Reviews

  @slug "demo-review"
  @github_id 10_001

  def slug, do: @slug

  def seed! do
    author = seed_author!()
    raw_diff = File.read!(Path.join(examples_dir(), "section_review_performance.patch"))

    packet =
      examples_dir()
      |> Path.join("section_review_performance.packet.md")
      |> File.read!()
      |> parse_packet_markdown()

    if review = Reviews.get_review_by_slug(@slug) do
      Repo.delete!(review)
    end

    {:ok, %{review: review}} =
      Reviews.create_review_with_initial_patchset(author, %{
        slug: @slug,
        title: packet["title"],
        description: packet["summary"],
        raw_diff: raw_diff,
        packet: packet,
        branch_name: "demo/structured-markdown-review-packets"
      })

    review
  end

  defp seed_author! do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: @github_id,
        username: "reviews-demo",
        avatar_url: nil,
        email: nil
      })

    user
  end

  defp examples_dir do
    case :code.priv_dir(:reviews) do
      {:error, _reason} -> Path.expand("../priv/examples", File.cwd!())
      path -> path |> List.to_string() |> Path.join("examples")
    end
  end

  defp parse_packet_markdown(markdown) do
    markdown
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> parse_lines()
  end

  defp parse_lines(lines) do
    {title, rest} = take_title(lines)
    {summary_lines, section_lines} = Enum.split_while(rest, &(not String.starts_with?(&1, "## ")))

    %{
      "format_version" => 1,
      "title" => title,
      "summary" => summary_lines |> Enum.join("\n") |> String.trim(),
      "sections" => parse_sections(section_lines)
    }
  end

  defp take_title(lines) do
    case Enum.split_while(lines, &(not String.starts_with?(&1, "# "))) do
      {_before_title, ["# " <> title | rest]} -> {String.trim(title), rest}
      _ -> raise "demo packet markdown must start with a # title"
    end
  end

  defp parse_sections(lines) do
    {sections, current, prose} =
      Enum.reduce(lines, {[], nil, []}, fn line, {sections, current, prose} ->
        cond do
          String.starts_with?(line, "## ") ->
            sections = maybe_add_section(sections, current, prose)

            {sections,
             %{"title" => line |> String.trim_leading("## ") |> String.trim(), "rows" => []}, []}

          String.starts_with?(line, "@hunk ") ->
            current = ensure_section!(current)
            {current, _prose} = flush_prose(current, prose)
            {sections, add_hunk_row(current, line), []}

          true ->
            {sections, current, [line | prose]}
        end
      end)

    sections
    |> maybe_add_section(current, prose)
    |> Enum.reverse()
  end

  defp maybe_add_section(sections, nil, _prose), do: sections

  defp maybe_add_section(sections, current, prose) do
    {current, _prose} = flush_prose(current, prose)
    [current | sections]
  end

  defp ensure_section!(nil), do: raise("demo packet markdown has @hunk before a ## section")
  defp ensure_section!(section), do: section

  defp flush_prose(current, prose) do
    body =
      prose
      |> Enum.reverse()
      |> Enum.join("\n")
      |> String.trim()

    current =
      if body == "" do
        current
      else
        update_in(current["rows"], &(&1 ++ [%{"kind" => "markdown", "body" => body}]))
      end

    {current, []}
  end

  defp add_hunk_row(current, "@hunk " <> ref) do
    case Regex.run(~r/^(.+?)#(\d+)(?::L(\d+)-L(\d+))?$/, String.trim(ref)) do
      [_match, path, hunk_index] ->
        add_row(current, %{
          "kind" => "hunk",
          "path" => path,
          "hunk_index" => String.to_integer(hunk_index)
        })

      [_match, path, hunk_index, line_start, line_end] ->
        add_row(current, %{
          "kind" => "hunk",
          "path" => path,
          "hunk_index" => String.to_integer(hunk_index),
          "line_start" => String.to_integer(line_start),
          "line_end" => String.to_integer(line_end)
        })

      _ ->
        raise "invalid demo packet hunk reference: @hunk #{ref}"
    end
  end

  defp add_row(current, row), do: update_in(current["rows"], &(&1 ++ [row]))
end
