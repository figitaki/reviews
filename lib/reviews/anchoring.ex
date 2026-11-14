defmodule Reviews.Anchoring do
  @moduledoc """
  Pure, conservative projection of an original thread anchor onto a patchset.

  Only lines present in the target unified diff are known. Matches are exact,
  on the same file path and diff side; missing or ambiguous matches are outdated.
  No original anchors or thread statuses are persisted by this module.
  """

  alias Reviews.Reviews, as: ReviewsContext

  def relocate(thread, old_patchset, new_patchset) do
    anchor = Map.get(thread, :anchor, thread)

    if anchor["granularity"] in ["line", "token_range"] do
      source = lines(thread, old_patchset)
      target = lines(thread, new_patchset)
      text = anchor["line_text"] || source[anchor["line_number_hint"]]

      matches =
        target
        |> Enum.filter(fn {_number, line} -> is_binary(text) and line == text end)

      # A deleted copy must not jump to a surviving identical line. The browser
      # currently sends empty context, so recover it from the original revision.
      repeated_source? = Enum.count(source, fn {_, line} -> line == text end) > 1
      anchor = source_context(anchor, source, text)

      matches =
        if length(matches) > 1 or repeated_source? do
          Enum.filter(matches, fn {number, _} -> context_matches?(anchor, target, number) end)
        else
          matches
        end

      case matches do
        [{number, line}] ->
          with :ok <- selection_matches(anchor, line) do
            {:ok, Map.put(anchor, "line_number_hint", number)}
          end

        _ ->
          {:error, :outdated}
      end
    else
      {:error, :unknown_granularity}
    end
  end

  defp selection_matches(%{"granularity" => "line"}, _line), do: :ok

  defp selection_matches(anchor, line) do
    selection = anchor["selection_text"]
    offset = anchor["selection_offset"]

    cond do
      not is_binary(selection) or selection == "" ->
        {:error, :outdated}

      is_integer(offset) and offset >= 0 ->
        # Browser offsets count UTF-16 code units, not UTF-8 bytes or graphemes.
        encoded = :unicode.characters_to_binary(line, :utf8, {:utf16, :little})
        selected = :unicode.characters_to_binary(selection, :utf8, {:utf16, :little})
        start = offset * 2

        if start + byte_size(selected) <= byte_size(encoded) and
             binary_part(encoded, start, byte_size(selected)) == selected,
           do: :ok,
           else: {:error, :outdated}

      is_nil(offset) and length(:binary.matches(line, selection)) == 1 ->
        :ok

      true ->
        {:error, :outdated}
    end
  end

  defp source_context(anchor, source, text) do
    number = anchor["line_number_hint"]

    if is_integer(number) and source[number] == text do
      Enum.reduce([{"context_before", -1}, {"context_after", 1}], anchor, fn {key, step}, acc ->
        if (acc[key] || []) == [] do
          context =
            1..3
            |> Enum.map(&source[number + &1 * step])
            |> Enum.take_while(&is_binary/1)

          Map.put(acc, key, if(step == -1, do: Enum.reverse(context), else: context))
        else
          acc
        end
      end)
    else
      anchor
    end
  end

  defp context_matches?(anchor, lines, number) do
    before = anchor["context_before"] || []
    after_lines = anchor["context_after"] || []

    (before != [] or after_lines != []) and
      Enum.with_index(before, number - length(before))
      |> Enum.concat(Enum.with_index(after_lines, number + 1))
      |> Enum.all?(fn {text, position} -> lines[position] == text end)
  end

  defp lines(thread, patchset) do
    path = Map.get(thread, :file_path)
    side = Map.get(thread, :side)

    file =
      patchset
      |> Map.get(:raw_diff, "")
      |> ReviewsContext.parse_diff_files()
      |> Enum.find(&(&1.path == path))

    if file && side in ["old", "new"] do
      {_, _, _, lines} =
        Enum.reduce(String.split(file.raw_diff, "\n"), {nil, nil, false, %{}}, fn line,
                                                                                  {old, new,
                                                                                   active, acc} ->
          case Regex.run(~r/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/, line) do
            [_, old, new] -> {String.to_integer(old), String.to_integer(new), true, acc}
            _ -> diff_line(line, old, new, active, acc, side)
          end
        end)

      lines
    else
      %{}
    end
  end

  defp diff_line(<<prefix, text::binary>>, old, new, true, acc, side)
       when prefix in [?\s, ?+, ?-] do
    number = if side == "old", do: old, else: new

    visible =
      prefix == ?\s or (prefix == ?+ and side == "new") or (prefix == ?- and side == "old")

    acc = if visible, do: Map.put(acc, number, text), else: acc
    {old + if(prefix == ?+, do: 0, else: 1), new + if(prefix == ?-, do: 0, else: 1), true, acc}
  end

  defp diff_line(_line, old, new, active, acc, _side), do: {old, new, active, acc}
end
