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
    expected =
      for {path, hunks} <- hunks_by_path,
          hunk <- hunks,
          {line, n} <- Enum.with_index(ReviewHunks.rows(hunk), 1),
          String.starts_with?(line, ["+", "-"]),
          into: MapSet.new(),
          do: {path, hunk.hunk_index, n}

    {problems, covered} =
      packet["sections"]
      |> Enum.flat_map(& &1["rows"])
      |> Enum.filter(&(&1["kind"] == "hunk"))
      |> Enum.reduce({[], %{}}, fn row, {problems, covered} ->
        case reference(row, hunks_by_path) do
          {:ok, first, last} ->
            keys =
              for n <- first..last//1,
                  key = {row["path"], row["hunk_index"], n},
                  MapSet.member?(expected, key),
                  do: key

            covered =
              Enum.reduce(keys, covered, &Map.update(&2, &1, 1, fn count -> count + 1 end))

            {problems, covered}

          {:error, issue} ->
            {[issue | problems], covered}
        end
      end)

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

  defp reference(row, hunks) do
    ref = "#{row["path"]}##{row["hunk_index"]}"

    case ReviewHunks.find(hunks, row["path"], row["hunk_index"]) do
      nil -> {:error, problem("unknown_hunk", "#{ref} is not a hunk in raw_diff")}
      hunk -> slice(row, length(ReviewHunks.rows(hunk)), ref)
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
