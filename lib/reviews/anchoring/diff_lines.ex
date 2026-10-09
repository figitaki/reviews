defmodule Reviews.Anchoring.DiffLines do
  @moduledoc """
  Pure helpers that read file lines out of a patchset's unified diff.

  Patchsets store only `raw_diff`, so the lines we can search are the lines
  the diff shows: context lines plus `-` lines on the "old" side, and context
  lines plus `+` lines on the "new" side. Lines outside every hunk are not
  known and are absent from the result.
  """

  @type side :: String.t()
  @type lines :: %{pos_integer() => String.t()}
  @type file_entry :: %{path: String.t(), old_path: String.t() | nil, raw_diff: String.t()}

  @hunk_header ~r/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

  @doc """
  Finds the file entry for `path` in a patchset (a `%Patchset{}` or any map
  with `:raw_diff` / `"raw_diff"`).

  Matches the new path first, then the pre-rename path, then any of
  `also_match` (used to follow a file that was renamed in an earlier
  patchset). Returns `nil` when the file is not in the diff.
  """
  @spec find_file(map(), String.t() | nil, [String.t()]) :: file_entry() | nil
  def find_file(patchset, path, also_match \\ [])

  def find_file(_patchset, nil, _also_match), do: nil

  def find_file(patchset, path, also_match) do
    files = patchset |> raw_diff() |> Reviews.Reviews.parse_diff_files()
    wanted = Enum.reject([path | also_match], &is_nil/1)

    Enum.find(files, &(&1.path == path)) ||
      Enum.find(files, &(&1.old_path == path)) ||
      Enum.find(files, fn file -> file.path in wanted or file.old_path in wanted end)
  end

  @doc """
  Returns `%{line_number => text}` for one side (`"old"` or `"new"`) of a
  single-file diff chunk. Text is returned without the `+`/`-`/` ` prefix.
  """
  @spec side_lines(String.t() | nil, side()) :: lines()
  def side_lines(nil, _side), do: %{}

  def side_lines(raw_diff, side) when is_binary(raw_diff) and side in ["old", "new"] do
    raw_diff
    |> String.split("\n")
    |> Enum.reduce({nil, %{}}, &walk(&1, &2, side))
    |> elem(1)
  end

  def side_lines(_raw_diff, _side), do: %{}

  @doc """
  Up to `size` lines next to `line_no` in `lines`, in file order. `dir` is
  `-1` for lines above and `1` for lines below. Stops at a gap between hunks,
  because lines there are unknown.
  """
  @spec neighbours(lines(), integer(), -1 | 1, non_neg_integer()) :: [String.t()]
  def neighbours(_lines, _line_no, _dir, 0), do: []

  def neighbours(lines, line_no, dir, size) do
    found =
      1..size
      |> Enum.reduce_while([], fn step, acc ->
        case Map.fetch(lines, line_no + dir * step) do
          {:ok, text} -> {:cont, [text | acc]}
          :error -> {:halt, acc}
        end
      end)

    # `found` is nearest-last; lines above read top-down already, lines below
    # need reversing.
    if dir < 0, do: found, else: Enum.reverse(found)
  end

  # --- Internal -------------------------------------------------------------

  defp raw_diff(%{raw_diff: raw}) when is_binary(raw), do: raw
  defp raw_diff(%{"raw_diff" => raw}) when is_binary(raw), do: raw
  defp raw_diff(_), do: nil

  # State is `nil` outside a hunk, or `{old_no, new_no, old_left, new_left}`.
  defp walk(line, {state, acc}, side) do
    case Regex.run(@hunk_header, line) do
      [_ | captures] ->
        [old_start, old_count, new_start, new_count] = pad(captures)
        state = {old_start, new_start, old_count, new_count}
        {close_if_done(state), acc}

      nil ->
        step(line, state, acc, side)
    end
  end

  defp pad(captures) do
    [a, b, c, d] = captures ++ List.duplicate("", 4 - length(captures))
    [to_int(a, 1), to_int(b, 1), to_int(c, 1), to_int(d, 1)]
  end

  defp to_int("", default), do: default
  defp to_int(value, _default), do: String.to_integer(value)

  defp step(_line, nil, acc, _side), do: {nil, acc}

  defp step(line, {o, n, ol, nl}, acc, side) do
    case line do
      "\\" <> _ ->
        {{o, n, ol, nl}, acc}

      "-" <> text when ol > 0 ->
        acc = if side == "old", do: Map.put(acc, o, text), else: acc
        {close_if_done({o + 1, n, ol - 1, nl}), acc}

      "+" <> text when nl > 0 ->
        acc = if side == "new", do: Map.put(acc, n, text), else: acc
        {close_if_done({o, n + 1, ol, nl - 1}), acc}

      context when ol > 0 and nl > 0 ->
        # Some tools strip the leading space from blank context lines.
        text = String.replace_prefix(context, " ", "")
        acc = Map.put(acc, if(side == "old", do: o, else: n), text)
        {close_if_done({o + 1, n + 1, ol - 1, nl - 1}), acc}

      _other ->
        {nil, acc}
    end
  end

  defp close_if_done({_o, _n, 0, 0}), do: nil
  defp close_if_done(state), do: state
end
