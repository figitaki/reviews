defmodule Reviews.FileContext do
  @moduledoc "Validates optional full-context diffs against the canonical uploaded changes."

  alias Reviews.ReviewHunks
  alias Reviews.Reviews, as: ReviewsContext

  @max_bytes 4 * 1024 * 1024
  @max_file_bytes 1024 * 1024

  def from_diff(nil, _raw), do: {:ok, %{}}

  def from_diff(context_diff, raw)
      when is_binary(context_diff) and byte_size(context_diff) <= @max_bytes do
    canonical = Map.new(ReviewsContext.parse_diff_files(raw), &{&1.path, &1})

    context_diff
    |> ReviewsContext.parse_diff_files()
    |> Enum.reduce_while({:ok, %{}}, fn file, {:ok, contexts} ->
      case decode(file, canonical[file.path]) do
        {:ok, nil} -> {:cont, {:ok, contexts}}
        {:ok, context} -> {:cont, {:ok, Map.put(contexts, file.path, context)}}
        :error -> {:halt, invalid()}
      end
    end)
  end

  def from_diff(_, _), do: invalid()

  defp invalid do
    {:error,
     %Reviews.Reviews.Patchset{}
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(
       :context_diff,
       "must contain matching full-file context (4 MiB total, 1 MiB per file)"
     )}
  end

  defp decode(%{status: status}, _canonical) when status in ["added", "deleted"], do: {:ok, nil}
  defp decode(_file, nil), do: :error

  defp decode(file, canonical) do
    with [hunk] <- ReviewHunks.for_file(file),
         {old_start, old_count, new_start, new_count} <- coordinates(hunk),
         true <- old_start == if(old_count == 0, do: 0, else: 1),
         true <- new_start == if(new_count == 0, do: 0, else: 1),
         {old, new} <- contents(hunk.body_lines),
         true <- length(old) == old_count,
         true <- length(new) == new_count,
         true <- byte_size(Enum.join(old)) + byte_size(Enum.join(new)) <= @max_file_bytes,
         true <- changes(file) == changes(canonical),
         true <- matches_hunks?(canonical, old, new) do
      {:ok, %{"old" => Enum.join(old), "new" => Enum.join(new)}}
    else
      # Binary changes and pure renames have no text to expand.
      [] -> {:ok, nil}
      _ -> :error
    end
  end

  defp contents(lines) do
    {old, new, _side} =
      Enum.reduce(lines, {[], [], nil}, fn
        " " <> text, {old, new, _} ->
          {[text <> "\n" | old], [text <> "\n" | new], :both}

        "-" <> text, {old, new, _} ->
          {[text <> "\n" | old], new, :old}

        "+" <> text, {old, new, _} ->
          {old, [text <> "\n" | new], :new}

        "\\" <> _, {old, new, side} ->
          {if(side in [:both, :old], do: strip_newline(old), else: old),
           if(side in [:both, :new], do: strip_newline(new), else: new), side}

        _, state ->
          state
      end)

    {Enum.reverse(old), Enum.reverse(new)}
  end

  defp strip_newline([]), do: []
  defp strip_newline([line | rest]), do: [String.trim_trailing(line, "\n") | rest]

  defp changes(file) do
    file
    |> ReviewHunks.for_file()
    |> Enum.flat_map(fn hunk ->
      old_start = boundary(hunk, :old)
      new_start = boundary(hunk, :new)

      {events, _, _} =
        Enum.reduce(hunk.body_lines, {[], 0, 0}, fn line, {events, old, new} ->
          case line do
            " " <> _ -> {events, old + 1, new + 1}
            "-" <> text -> {[{:old, old_start + old, text} | events], old + 1, new}
            "+" <> text -> {[{:new, new_start + new, text} | events], old, new + 1}
            _ -> {events, old, new}
          end
        end)

      Enum.reverse(events)
    end)
  end

  defp matches_hunks?(file, old, new) do
    old = List.to_tuple(old)
    new = List.to_tuple(new)

    Enum.all?(ReviewHunks.for_file(file), fn hunk ->
      {old_rows, new_rows} = contents(hunk.body_lines)

      matches_rows?(old, boundary(hunk, :old), old_rows) and
        matches_rows?(new, boundary(hunk, :new), new_rows)
    end)
  end

  defp matches_rows?(source, offset, rows) do
    offset >= 0 and offset + length(rows) <= tuple_size(source) and
      Enum.all?(Enum.with_index(rows, offset), fn {line, index} -> elem(source, index) == line end)
  end

  defp boundary(hunk, side) do
    case coordinates(hunk) do
      {old, old_count, new, new_count} ->
        {start, count} = if side == :old, do: {old, old_count}, else: {new, new_count}
        start - if(count == 0, do: 0, else: 1)

      nil ->
        -1
    end
  end

  defp coordinates(hunk) do
    captures =
      Regex.named_captures(
        ~r/^@@ -(?<old>\d+)(?:,(?<old_count>\d+))? \+(?<new>\d+)(?:,(?<new_count>\d+))? @@/,
        hunk.hunk_header
      )

    if captures do
      {String.to_integer(captures["old"]), count(captures["old_count"]),
       String.to_integer(captures["new"]), count(captures["new_count"])}
    end
  end

  defp count(""), do: 1
  defp count(value), do: String.to_integer(value)
end
