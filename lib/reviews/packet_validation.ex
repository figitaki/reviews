defmodule Reviews.PacketValidation do
  @moduledoc "Validates packet shape, hunk references and exactly-once changed-row coverage."
  alias Reviews.ReviewHunks
  alias Reviews.Reviews, as: ReviewsContext

  @doc "Returns :ok or stable coded problems. A nil packet is optional."
  def check(nil, _raw_diff), do: :ok

  def check(packet, raw_diff) when is_map(packet) and is_binary(raw_diff) do
    case shape(packet) do
      [] ->
        check_coverage(packet, ReviewHunks.for_files(ReviewsContext.parse_diff_files(raw_diff)))

      problems ->
        {:error, problems}
    end
  end

  def check(_, _),
    do: {:error, [problem("shape", "packet must be an object with a valid raw_diff")]}

  defp shape(%{"title" => title, "sections" => sections}) when is_list(sections) do
    title_problems(title, "packet") ++ Enum.flat_map(sections, &section_shape/1)
  end

  defp shape(_), do: [problem("shape", "packet requires a title and sections array")]

  defp section_shape(%{"title" => title, "rows" => rows}) when is_list(rows) do
    title_problems(title, "section") ++ Enum.flat_map(rows, &row_shape/1)
  end

  defp section_shape(_), do: [problem("shape", "each section requires a title and rows array")]

  defp title_problems(title, label) do
    case nonblank?(title) do
      true -> []
      false -> [problem("shape", "#{label} title must be a nonblank string")]
    end
  end

  defp row_shape(%{"kind" => "markdown", "body" => body}) when is_binary(body), do: []

  defp row_shape(%{"kind" => "hunk", "path" => path, "hunk_index" => index}) do
    case nonblank?(path) and is_integer(index) and index > 0 do
      true ->
        []

      false ->
        [problem("shape", "hunk rows require a nonblank path and positive integer hunk_index")]
    end
  end

  defp row_shape(_),
    do: [problem("shape", "rows must be markdown with a string body or a hunk reference")]

  defp nonblank?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank?(_), do: false

  defp check_coverage(packet, hunks_by_path) do
    row_counts =
      for {path, hunks} <- hunks_by_path,
          hunk <- hunks,
          into: %{},
          do: {{path, hunk.hunk_index}, length(ReviewHunks.rows(hunk))}

    expected =
      for {path, hunks} <- hunks_by_path,
          hunk <- hunks,
          {line, n} <- Enum.with_index(ReviewHunks.rows(hunk), 1),
          String.starts_with?(line, ["+", "-"]),
          into: MapSet.new(),
          do: {path, hunk.hunk_index, n}

    {problems, boundaries} =
      packet["sections"]
      |> Enum.flat_map(& &1["rows"])
      |> Enum.filter(&(&1["kind"] == "hunk"))
      |> Enum.reduce({[], %{}}, fn row, {problems, boundaries} ->
        case reference(row, row_counts) do
          {:ok, first, last} ->
            key = {row["path"], row["hunk_index"]}
            events = [{first, 1}, {last + 1, -1}]
            boundaries = Map.update(boundaries, key, events, &(events ++ &1))
            {problems, boundaries}

          {:error, issue} ->
            {[issue | problems], boundaries}
        end
      end)

    covered = coverage_counts(expected, boundaries)

    missing =
      expected
      |> Enum.reject(&Map.has_key?(covered, &1))
      |> Enum.sort()
      |> Enum.map(
        &problem("uncovered_line", "changed line #{location(&1)} is not in any hunk row")
      )

    repeated =
      covered
      |> Enum.filter(fn {_, count} -> count > 1 end)
      |> Enum.sort()
      |> Enum.map(fn {key, count} ->
        problem("repeated_line", "changed line #{location(key)} is covered #{count} times")
      end)

    case Enum.reverse(problems) ++ missing ++ repeated do
      [] -> :ok
      issues -> {:error, issues}
    end
  end

  # Sweep sorted slice boundaries only at changed rows. Context-only overlaps
  # cost two events per reference, regardless of the lengths of their slices.
  defp coverage_counts(expected, boundaries) do
    expected
    |> Enum.group_by(fn {path, hunk, _} -> {path, hunk} end)
    |> Enum.reduce(%{}, fn {key, rows}, covered ->
      events = boundaries |> Map.get(key, []) |> Enum.sort()

      {covered, _, _} =
        rows
        |> Enum.sort()
        |> Enum.reduce({covered, events, 0}, fn {_, _, row} = location, {acc, events, count} ->
          {before, remaining} = Enum.split_while(events, fn {position, _} -> position <= row end)
          count = Enum.reduce(before, count, fn {_, delta}, total -> total + delta end)
          acc = if count > 0, do: Map.put(acc, location, count), else: acc
          {acc, remaining, count}
        end)

      covered
    end)
  end

  defp reference(row, row_counts) do
    ref = "#{row["path"]}##{row["hunk_index"]}"

    case Map.fetch(row_counts, {row["path"], row["hunk_index"]}) do
      :error -> {:error, problem("unknown_hunk", "#{ref} is not a hunk in raw_diff")}
      {:ok, count} -> slice(row, count, ref)
    end
  end

  defp slice(row, count, ref) do
    case {Map.fetch(row, "line_start"), Map.fetch(row, "line_end")} do
      {:error, :error} ->
        {:ok, 1, count}

      {{:ok, first}, {:ok, last}}
      when is_integer(first) and is_integer(last) and first >= 1 and first <= last and
             last <= count ->
        {:ok, first, last}

      {:error, _} ->
        {:error,
         problem("invalid_slice", "#{ref} needs both line_start and line_end, or neither")}

      {_, :error} ->
        {:error,
         problem("invalid_slice", "#{ref} needs both line_start and line_end, or neither")}

      _ ->
        {:error,
         problem(
           "invalid_slice",
           "#{ref} slice is outside the hunk, which has #{count} rows; bounds must be integers"
         )}
    end
  end

  defp location({path, hunk, row}), do: "#{path}##{hunk}:L#{row}"
  defp problem(code, detail), do: %{code: "invalid_packet." <> code, detail: detail}
end
