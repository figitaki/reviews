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
    |> parse_hunks(path || file.old_path || "", file.status)
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
      partial_line_range? = partial_line_range?(hunk, line_start, line_end)

      Map.merge(hunk, %{
        display_raw_diff: display_raw_diff,
        display_additions: additions,
        display_deletions: deletions,
        partial_line_range?: partial_line_range?,
        line_start: line_start || hunk.line_start,
        line_end: line_end || hunk.line_end
      })
    end
  end

  def combine_consecutive([hunk]), do: hunk

  def combine_consecutive([first | _] = hunks) do
    viewed_count = Enum.count(hunks, & &1.viewed?)

    first
    |> Map.merge(%{
      id: combined_hunk_dom_id(hunks),
      grouped_hunks: hunks,
      hunk_index: first.hunk_index,
      hunk_indices: Enum.map(hunks, & &1.hunk_index),
      line_start: first.line_start,
      line_end: List.last(hunks).line_end,
      display_additions: Enum.sum(Enum.map(hunks, & &1.display_additions)),
      display_deletions: Enum.sum(Enum.map(hunks, & &1.display_deletions)),
      display_raw_diff: combine_raw_diffs(hunks),
      viewed_count: viewed_count,
      viewed?: viewed_count == length(hunks),
      partially_viewed?: viewed_count > 0 && viewed_count < length(hunks),
      grouped?: true
    })
  end

  defp parse_hunks(raw_diff, file_path, status) when is_binary(raw_diff) do
    lines = String.split(raw_diff, "\n", trim: false)
    {header_lines, rest} = Enum.split_while(lines, &(not String.starts_with?(&1, "@@ ")))
    header = Enum.join(header_lines, "\n")

    chunks = chunk_hunks(rest)
    last_index = length(chunks)
    terminated? = String.ends_with?(raw_diff, "\n")

    chunks
    |> Enum.with_index(1)
    |> Enum.map(fn {lines, index} ->
      body = body_lines(lines, index == last_index and terminated?)
      raw = Enum.join(header_lines ++ [hd(lines) | body], "\n") <> "\n"
      {additions, deletions} = changed_line_stats(raw)
      {line_start, line_end} = hunk_line_range(List.first(lines), status)

      %{
        id: hunk_dom_id(file_path, index),
        file_path: file_path,
        row_ref: "#{file_path}##{index}",
        hunk_index: index,
        hunk_header: List.first(lines) || "",
        body_lines: body,
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

  defp parse_hunks(_raw_diff, _file_path, _status), do: []

  # A terminal newline ends the last row; interior empty lines are real rows.
  defp body_lines([_header | lines], true), do: Enum.drop(lines, -1)
  defp body_lines([_header | lines], false), do: lines

  @doc "Hunk body rows in CLI order, excluding no-newline markers."
  def rows(%{body_lines: lines}) do
    Enum.reject(lines, &String.starts_with?(&1, "\\"))
  end

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
    [hunk_header | _] = rest

    # Rows are numbered as the CLI validates slices: "\\ No newline" markers
    # are not rows, and stay with the row they follow.
    {kept, _row, _kept?} =
      hunk.body_lines
      |> Enum.reduce({[], 0, false}, fn line, {acc, row, prev_kept?} ->
        if String.starts_with?(line, "\\") do
          {if(prev_kept?, do: [line | acc], else: acc), row, prev_kept?}
        else
          row = row + 1
          keep? = row >= line_start and row <= line_end
          {if(keep?, do: [line | acc], else: acc), row, keep?}
        end
      end)

    hunk_lines = Enum.reverse(kept)
    prefix = hunk |> rows() |> Enum.take(line_start - 1)
    hunk_header = slice_header(hunk_header, prefix, hunk_lines)

    Enum.join(header_lines ++ [hunk_header | hunk_lines], "\n") <> "\n"
  end

  defp slice_hunk(hunk, _line_start, _line_end), do: hunk.raw_diff

  # Hunk slice bounds are body-row indices, not source line numbers. Advance
  # each side independently, retaining Git's boundary semantics for zero counts.
  defp slice_header(header, prefix, selected) do
    Regex.replace(~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/, header, fn _,
                                                                              old,
                                                                              old_count,
                                                                              new,
                                                                              new_count ->
      {old_prefix, new_prefix} = source_counts(prefix)
      {old_size, new_size} = source_counts(selected)
      old_start = slice_start(old, old_count, old_prefix, old_size)
      new_start = slice_start(new, new_count, new_prefix, new_size)
      "@@ -#{old_start},#{old_size} +#{new_start},#{new_size} @@"
    end)
  end

  defp source_counts(lines) do
    Enum.reduce(lines, {0, 0}, fn
      " " <> _, {old, new} -> {old + 1, new + 1}
      "-" <> _, {old, new} -> {old + 1, new}
      "+" <> _, {old, new} -> {old, new + 1}
      _, counts -> counts
    end)
  end

  defp slice_start(start, count, consumed, size) do
    boundary = String.to_integer(start) - if(count == "0", do: 0, else: 1)
    boundary + consumed + if(size > 0, do: 1, else: 0)
  end

  defp partial_line_range?(hunk, line_start, line_end)
       when is_integer(line_start) and is_integer(line_end) do
    line_start != 1 || line_end != length(rows(hunk))
  end

  defp partial_line_range?(_hunk, _line_start, _line_end), do: false

  # File headers (`--- a/`, `+++ b/`) only come before the first `@@`; inside a
  # hunk, a row like `--- note` is a removed `-- note` line.
  defp changed_line_stats(raw_diff) do
    raw_diff
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "@@ ")))
    |> Enum.reduce({0, 0}, fn line, {additions, deletions} ->
      cond do
        String.starts_with?(line, "+") ->
          {additions + 1, deletions}

        String.starts_with?(line, "-") ->
          {additions, deletions + 1}

        true ->
          {additions, deletions}
      end
    end)
  end

  defp combine_raw_diffs([first | rest]) do
    header_lines = file_header_lines(first.display_raw_diff)

    hunk_blocks =
      [first | rest]
      |> Enum.flat_map(&hunk_block_lines(&1.display_raw_diff))

    Enum.join(header_lines ++ hunk_blocks, "\n") <> "\n"
  end

  defp file_header_lines(raw_diff) do
    raw_diff
    |> String.split("\n", trim: false)
    |> Enum.take_while(&(not String.starts_with?(&1, "@@ ")))
  end

  defp hunk_block_lines(raw_diff) do
    raw_diff
    |> strip_terminator()
    |> String.split("\n", trim: false)
    |> Enum.drop_while(&(not String.starts_with?(&1, "@@ ")))
  end

  defp strip_terminator(raw) do
    if String.ends_with?(raw, "\n"), do: binary_part(raw, 0, byte_size(raw) - 1), else: raw
  end

  defp hunk_line_range(header, "deleted") when is_binary(header) do
    hunk_line_range_with(header, ~r/@@ -(\d+)(?:,(\d+))? \+\d+(?:,\d+)? @@/)
  end

  defp hunk_line_range(header, _status) when is_binary(header) do
    hunk_line_range_with(header, ~r/@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/)
  end

  defp hunk_line_range(_header, _status), do: {nil, nil}

  defp hunk_line_range_with(header, regex) do
    case Regex.run(regex, header) do
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

  defp combined_hunk_dom_id(hunks) do
    first = List.first(hunks)
    last = List.last(hunks)

    "#{first.id}-through-#{last.hunk_index}"
  end
end
