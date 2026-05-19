defmodule Reviews.ReviewHunks do
  @moduledoc """
  Shared hunk read model for packet sections and the classic changes view.
  """

  alias Reviews.PacketHunkViews
  alias Reviews.ReviewPacket

  def for_files(files, views \\ []) when is_list(files) do
    Map.new(files, fn file ->
      hunks = for_file(file, views)
      {file.path, hunks}
    end)
  end

  def for_file(%{path: path, raw_diff: raw_diff} = file, views \\ []) do
    raw_diff
    |> parse_hunks(path || file.old_path || "")
    |> Enum.map(&Map.put(&1, :viewed?, PacketHunkViews.viewed?(views, &1)))
  end

  def find(hunks_by_path, path, hunk_index) do
    hunks_by_path
    |> Map.get(path, [])
    |> Enum.find(&(&1.hunk_index == hunk_index))
  end

  def for_packet_row(hunks_by_path, row) do
    path = ReviewPacket.text(row, "path")
    hunk_index = ReviewPacket.int(row, "hunk_index")

    with hunk when not is_nil(hunk) <- find(hunks_by_path, path, hunk_index) do
      line_start = ReviewPacket.int(row, "line_start")
      line_end = ReviewPacket.int(row, "line_end")
      display_raw_diff = slice_hunk(hunk, line_start, line_end)
      {additions, deletions} = changed_line_stats(display_raw_diff)

      %{
        hunk
        | display_raw_diff: display_raw_diff,
          display_additions: additions,
          display_deletions: deletions,
          line_start: line_start || hunk.line_start,
          line_end: line_end || hunk.line_end
      }
    end
  end

  def attrs_for_view(hunk, extra \\ %{}) do
    %{
      file_path: hunk.file_path,
      row_ref: hunk.row_ref,
      hunk_fingerprint: hunk.hunk_fingerprint,
      hunk_index: hunk.hunk_index,
      line_start: hunk.line_start,
      line_end: hunk.line_end
    }
    |> Map.merge(extra)
  end

  defp parse_hunks(raw_diff, file_path) when is_binary(raw_diff) do
    lines = String.split(raw_diff, "\n", trim: false)
    {header_lines, rest} = Enum.split_while(lines, &(not String.starts_with?(&1, "@@ ")))
    header = Enum.join(header_lines, "\n")

    rest
    |> chunk_hunks()
    |> Enum.with_index(1)
    |> Enum.map(fn {lines, index} ->
      raw = Enum.join(header_lines ++ lines, "\n")
      {additions, deletions} = changed_line_stats(raw)
      {line_start, line_end} = hunk_line_range(List.first(lines))

      %{
        id: hunk_dom_id(file_path, index),
        file_path: file_path,
        row_ref: "#{file_path}##{index}",
        hunk_index: index,
        hunk_header: List.first(lines) || "",
        line_start: line_start,
        line_end: line_end,
        additions: additions,
        deletions: deletions,
        display_additions: additions,
        display_deletions: deletions,
        raw_diff: raw,
        display_raw_diff: raw,
        hunk_fingerprint: fingerprint("#{header}\n#{Enum.join(lines, "\n")}"),
        viewed?: false
      }
    end)
  end

  defp parse_hunks(_raw_diff, _file_path), do: []

  defp chunk_hunks(lines) do
    {chunks, current} =
      Enum.reduce(lines, {[], []}, fn line, {chunks, current} ->
        cond do
          String.starts_with?(line, "@@ ") && current == [] ->
            {chunks, [line]}

          String.starts_with?(line, "@@ ") ->
            {[Enum.reverse(current) | chunks], [line]}

          current == [] ->
            {chunks, current}

          true ->
            {chunks, [line | current]}
        end
      end)

    chunks =
      case current do
        [] -> chunks
        _ -> [Enum.reverse(current) | chunks]
      end

    Enum.reverse(chunks)
  end

  defp slice_hunk(hunk, nil, nil), do: hunk.raw_diff

  defp slice_hunk(hunk, line_start, line_end)
       when is_integer(line_start) and is_integer(line_end) do
    lines = String.split(hunk.raw_diff, "\n", trim: false)
    {header_lines, rest} = Enum.split_while(lines, &(not String.starts_with?(&1, "@@ ")))
    [hunk_header | hunk_lines] = rest

    hunk_lines =
      hunk_lines
      |> Enum.reject(&(&1 == ""))
      |> Enum.slice((line_start - 1)..(line_end - 1))

    Enum.join(header_lines ++ [hunk_header | hunk_lines], "\n")
  end

  defp slice_hunk(hunk, _line_start, _line_end), do: hunk.raw_diff

  defp changed_line_stats(raw_diff) do
    Enum.reduce(String.split(raw_diff, "\n"), {0, 0}, fn line, {additions, deletions} ->
      cond do
        String.starts_with?(line, "+") && !String.starts_with?(line, "+++") ->
          {additions + 1, deletions}

        String.starts_with?(line, "-") && !String.starts_with?(line, "---") ->
          {additions, deletions + 1}

        true ->
          {additions, deletions}
      end
    end)
  end

  defp hunk_line_range(header) when is_binary(header) do
    case Regex.run(~r/@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/, header) do
      [_, start, count] ->
        start = String.to_integer(start)
        count = String.to_integer(count)
        {start, start + max(count - 1, 0)}

      [_, start] ->
        start = String.to_integer(start)
        {start, start}

      _ ->
        {nil, nil}
    end
  end

  defp hunk_line_range(_), do: {nil, nil}

  defp fingerprint(text) do
    :crypto.hash(:sha256, text)
    |> Base.encode16(case: :lower)
  end

  defp hunk_dom_id(file_path, index) do
    slug =
      file_path
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_-]+/, "-")
      |> String.trim("-")

    "hunk-#{slug}-#{index}"
  end
end
