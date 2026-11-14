defmodule Reviews.Anchoring do
  @moduledoc """
  Pure functions for relocating a `Threads.Thread` across patchsets.

  Dispatches on `thread.anchor["granularity"]`:

    * `"line"`        — line-level anchor. Relocated by content, see below.
    * `"token_range"` — token-level anchor. Schema reserved for v1.5. Returns
                        `{:error, :not_implemented}` — locks the dispatch in.

  Any other granularity returns `{:error, :unknown_granularity}`.

  This module is intentionally **pure** — no Ecto, no Repo. The caller is
  responsible for persisting any updated anchor or marking the thread
  `"outdated"`.

  ## Line relocation

  The searchable content is the lines each patchset's diff shows for the
  thread's file and side (see `Reviews.Anchoring.DiffLines`). Text is compared
  after normalization: trim both ends and collapse runs of whitespace, so
  re-indenting a line does not count as an edit.

  The target is the anchor's `line_text`, `context_before` and
  `context_after`. When the anchor has no context (the JS client sends `[]`
  today), or no `line_text`, they are read from the old patchset at
  `line_number_hint` — but only when the text there still equals
  `line_text`, so a stale hint never supplies wrong context.

  Context agreement for a candidate line is the share of the anchor's context
  lines found among the candidate's `context_size + 1` nearest lines on the
  same side. The extra line tolerates one line inserted or removed nearby.

  Tiers, first hit wins:

    1. **Exact** — lines whose normalized text equals the target. The
       candidate with the highest context agreement wins. A line that is
       short (under `:min_unique_length` characters) or appeared more than
       once in the old patchset needs at least `:context_threshold`
       agreement, so a deleted `end` or a deleted copy of `return 0;` never
       jumps to another copy just because a blank line or a brace is nearby.
       A distinctive line that was unique, with no context agreement, is
       still accepted.
    2. **Context** — the line was edited in place: every side of the anchor's
       context reaches `:context_threshold` agreement, and the line's text
       similarity is at least `:context_line_similarity`.
    3. **Fuzzy** — a distinctive line within `:fuzzy_window` lines of the
       hint whose text similarity is at least `:fuzzy_threshold`. Context
       agreement breaks near-ties.
    4. Otherwise `{:error, :outdated}`.

  Similarity is `1 - levenshtein(a, b) / max(len(a), len(b))` on normalized
  text. Tiers 2 and 3 skip a candidate whose text was already in the old
  patchset or equals one of the anchor's context lines: that is a line that
  was there all along, often a neighbour that slid into a deleted line's
  place, not an edit of the anchored line.

  When the best score in a tier is shared by two or more lines, the result is
  `{:error, :ambiguous}` — the relocator never picks one arbitrarily.

  ## Results

    * `{:ok, anchor}` — the anchor with `line_number_hint`, `line_text`,
      `context_before` and `context_after` refreshed from the new patchset,
      plus a `"relocation"` map: `"method"` (`"exact"`, `"context"` or
      `"fuzzy"`), `"score"` (0.0–1.0), `"from_line"` (the old hint) and
      `"file_path"` (the file's path in the new patchset; differs from the
      thread's path after a rename).
    * `{:error, :outdated}` — the target is gone, or its file is not in the
      new diff. Keep the old anchor as the last known position and set the
      thread status to `"outdated"`.
    * `{:error, :ambiguous}` — several lines match equally well. The UI has
      no separate status for this; treat it as `"outdated"` until a
      reattach flow exists.
  """

  alias Reviews.Anchoring.DiffLines

  @type anchor :: %{required(String.t()) => term()}
  @type result :: {:ok, anchor()} | {:error, atom()}

  @default_opts [
    context_size: 3,
    min_unique_length: 8,
    context_threshold: 0.5,
    context_line_similarity: 0.5,
    fuzzy_threshold: 0.75,
    fuzzy_window: 40,
    max_fuzzy_length: 500
  ]

  @doc """
  Relocates `thread` (a `%Thread{}`, a thread-shaped map, or a bare anchor
  map) from `old_patchset` to `new_patchset`.

  Patchsets are `%Patchset{}` structs or maps with `:raw_diff`/`"raw_diff"`.

  ## Options

    * `:file_path` / `:side` — used when `thread` is a bare anchor.
      `:side` defaults to `"new"`.
    * `:context_size` (3) — context lines kept and compared on each side.
    * `:min_unique_length` (8) — normalized length at which a line is
      distinctive enough to match without context, or fuzzily.
    * `:context_threshold` (0.5) — tier 2 per-side context agreement.
    * `:context_line_similarity` (0.5) — tier 2 minimum line similarity.
    * `:fuzzy_threshold` (0.75) — tier 3 minimum line similarity.
    * `:fuzzy_window` (40) — tier 3 search distance from the hint, in lines.
    * `:max_fuzzy_length` (500) — longer lines only match exactly.
  """
  @spec relocate(map(), map(), map(), keyword()) :: result()
  def relocate(thread, old_patchset, new_patchset, opts \\ []) do
    anchor = thread_anchor(thread)

    case anchor["granularity"] do
      "line" ->
        opts = Keyword.merge(@default_opts, opts)
        relocate_line(anchor, thread_location(thread, opts), old_patchset, new_patchset, opts)

      "token_range" ->
        # TODO(v1.5): real token-range matching. Plan calls for matching
        # `token_text` within the file and disambiguating by surrounding
        # context. Stream 1 leaves it stubbed.
        {:error, :not_implemented}

      _other ->
        {:error, :unknown_granularity}
    end
  end

  # --- Line relocation ------------------------------------------------------

  defp relocate_line(anchor, {file_path, side}, old_patchset, new_patchset, opts) do
    old_file = DiffLines.find_file(old_patchset, file_path)
    renamed_from = if old_file, do: Enum.reject([old_file.old_path], &is_nil/1), else: []
    new_file = DiffLines.find_file(new_patchset, file_path, renamed_from)

    old_lines = DiffLines.side_lines(old_file && old_file.raw_diff, side)
    new_lines = DiffLines.side_lines(new_file && new_file.raw_diff, side)

    with %{} <- new_file,
         {:ok, target} <- target(anchor, old_lines, opts),
         {:ok, line_no, method, score} <- locate(target, new_lines, opts) do
      size = opts[:context_size]

      {:ok,
       Map.merge(anchor, %{
         "line_number_hint" => line_no,
         "line_text" => Map.fetch!(new_lines, line_no),
         "context_before" => DiffLines.neighbours(new_lines, line_no, -1, size),
         "context_after" => DiffLines.neighbours(new_lines, line_no, 1, size),
         "relocation" => %{
           "method" => method,
           "score" => Float.round(score * 1.0, 3),
           "from_line" => target.hint,
           "file_path" => new_file.path
         }
       })}
    else
      nil -> {:error, :outdated}
      {:error, _} = error -> error
    end
  end

  # Builds the normalized search target, filling gaps from the old patchset.
  defp target(anchor, old_lines, opts) do
    size = opts[:context_size]
    hint = if is_integer(anchor["line_number_hint"]), do: anchor["line_number_hint"]
    at_hint = hint && Map.get(old_lines, hint)

    text =
      case anchor["line_text"] do
        text when is_binary(text) and text != "" -> text
        _ -> at_hint
      end

    hint_valid? = is_binary(text) and is_binary(at_hint) and norm(at_hint) == norm(text)

    before = context(anchor["context_before"], hint_valid?, old_lines, hint, -1, size)
    after_ = context(anchor["context_after"], hint_valid?, old_lines, hint, 1, size)

    if is_binary(text) do
      old_texts = Enum.map(old_lines, fn {_line_no, line} -> norm(line) end)

      {:ok,
       %{
         text: norm(text),
         old_texts: MapSet.new(old_texts),
         copies_in_old: Enum.count(old_texts, &(&1 == norm(text))),
         hint: hint,
         before: before |> Enum.take(-size) |> Enum.map(&norm/1),
         after: after_ |> Enum.take(size) |> Enum.map(&norm/1)
       }}
    else
      {:error, :outdated}
    end
  end

  defp context([_ | _] = given, _hint_valid?, _old_lines, _hint, _dir, _size)
       when is_list(given),
       do: Enum.filter(given, &is_binary/1)

  defp context(_given, true, old_lines, hint, dir, size),
    do: DiffLines.neighbours(old_lines, hint, dir, size)

  defp context(_given, _hint_valid?, _old_lines, _hint, _dir, _size), do: []

  # Tiers and scoring work on normalized text, computed once per line.
  defp locate(target, new_lines, opts) do
    normed = Map.new(new_lines, fn {line_no, text} -> {line_no, norm(text)} end)

    candidates =
      normed
      |> Enum.sort()
      |> Enum.map(fn {line_no, text} -> %{line_no: line_no, text: text} end)

    with :next <- exact_tier(target, candidates, normed, opts),
         :next <- context_tier(target, candidates, normed, opts),
         :next <- fuzzy_tier(target, candidates, normed, opts) do
      {:error, :outdated}
    end
  end

  defp exact_tier(target, candidates, new_lines, opts) do
    scored =
      for %{text: text} = cand <- candidates, text == target.text do
        {cand.line_no, agreement(target, new_lines, cand.line_no, opts).total}
      end

    best = scored |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0.0 end)
    # Text alone identifies a line only when it is long enough and was the
    # only copy in the old patchset. Otherwise (`}`, `end`, a `return 0;`
    # that appears twice) it needs real context agreement: a blank line and
    # a brace nearby are not enough to tell copies apart.
    distinctive? = distinctive?(target.text, opts) and target.copies_in_old <= 1
    min_agreement = if distinctive?, do: 0, else: opts[:context_threshold]

    cond do
      scored == [] -> :next
      best > 0 and best >= min_agreement -> pick(scored, "exact")
      distinctive? -> pick(scored, "exact", 1.0)
      true -> :next
    end
  end

  defp context_tier(target, candidates, new_lines, opts) do
    if target.before == [] and target.after == [] do
      :next
    else
      threshold = opts[:context_threshold]
      min_sim = opts[:context_line_similarity]

      scored =
        for cand <- candidates,
            cand.text != target.text,
            not existing_line?(cand, target),
            agreement = agreement(target, new_lines, cand.line_no, opts),
            side_ok?(agreement.before, threshold) and side_ok?(agreement.after, threshold),
            sim = similarity(cand.text, target.text, min_sim, opts),
            sim >= min_sim do
          {cand.line_no, (agreement.total + sim) / 2}
        end

      if scored == [], do: :next, else: pick(scored, "context")
    end
  end

  defp fuzzy_tier(%{hint: nil}, _candidates, _new_lines, _opts), do: :next

  defp fuzzy_tier(target, candidates, new_lines, opts) do
    min_sim = opts[:fuzzy_threshold]
    window = opts[:fuzzy_window]

    if distinctive?(target.text, opts) do
      scored =
        for cand <- candidates,
            abs(cand.line_no - target.hint) <= window,
            cand.text != target.text,
            distinctive?(cand.text, opts),
            not existing_line?(cand, target),
            sim = similarity(cand.text, target.text, min_sim, opts),
            sim >= min_sim do
          # Context only breaks near-ties; similarity stays the score.
          bonus = agreement(target, new_lines, cand.line_no, opts).total * 0.25
          {cand.line_no, sim, sim + bonus}
        end

      case scored do
        [] ->
          :next

        _ ->
          {_, _, top} = Enum.max_by(scored, &elem(&1, 2))

          case Enum.filter(scored, &(elem(&1, 2) == top)) do
            [{line_no, sim, _}] -> {:ok, line_no, "fuzzy", sim}
            _ -> {:error, :ambiguous}
          end
      end
    else
      :next
    end
  end

  # Unique best score wins; a shared best score is ambiguous.
  defp pick(scored, method, score_override \\ nil) do
    {_, top} = Enum.max_by(scored, &elem(&1, 1))

    case Enum.filter(scored, &(elem(&1, 1) == top)) do
      [{line_no, score}] -> {:ok, line_no, method, score_override || score}
      _ -> {:error, :ambiguous}
    end
  end

  # --- Scoring --------------------------------------------------------------

  # Share of the anchor's context lines found near `line_no`, per side and
  # overall. Each side is `{hits, total}`. `normed` holds normalized lines.
  defp agreement(target, normed, line_no, opts) do
    reach = opts[:context_size] + 1
    above = DiffLines.neighbours(normed, line_no, -1, reach)
    below = DiffLines.neighbours(normed, line_no, 1, reach)

    before = {hits(target.before, above), length(target.before)}
    after_ = {hits(target.after, below), length(target.after)}
    {bh, bt} = before
    {ah, at} = after_

    %{
      before: before,
      after: after_,
      total: if(bt + at == 0, do: 0.0, else: (bh + ah) / (bt + at))
    }
  end

  defp hits(wanted, nearby) do
    {count, _left} =
      Enum.reduce(wanted, {0, nearby}, fn line, {count, left} ->
        if line in left, do: {count + 1, List.delete(left, line)}, else: {count, left}
      end)

    count
  end

  defp side_ok?({_hits, 0}, _threshold), do: true
  defp side_ok?({hits, total}, threshold), do: hits / total >= threshold

  # A candidate whose text was already in the old patchset, or is one of the
  # anchor's context lines, is a different line that was there all along
  # (often a neighbour that slid into a deleted line's place), not an edit
  # of the anchored line.
  defp existing_line?(cand, target) do
    MapSet.member?(target.old_texts, cand.text) or cand.text in target.before or
      cand.text in target.after
  end

  defp distinctive?(text, opts), do: String.length(text) >= opts[:min_unique_length]

  # Levenshtein ratio. Returns 0.0 early when the length difference alone
  # rules out reaching `min`, when a line is too long to compare cheaply, or
  # as soon as the edit distance must exceed what `min` allows.
  defp similarity(a, b, min, opts) do
    la = String.length(a)
    lb = String.length(b)
    longest = max(la, lb)

    cond do
      longest == 0 ->
        1.0

      longest > opts[:max_fuzzy_length] ->
        0.0

      min(la, lb) / longest < min ->
        0.0

      true ->
        limit = floor((1 - min) * longest)

        case levenshtein(String.graphemes(a), String.graphemes(b), limit) do
          :over -> 0.0
          distance -> 1 - distance / longest
        end
    end
  end

  # Row-by-row edit distance. Gives up with `:over` once every cell in a row
  # exceeds `limit`, because the distance can only grow from there.
  defp levenshtein(a, b, limit) do
    first_row = Enum.to_list(0..length(b))
    lev_rows(a, b, first_row, 1, limit)
  end

  defp lev_rows([], _b, row, _i, limit) do
    distance = List.last(row)
    if distance > limit, do: :over, else: distance
  end

  defp lev_rows([char_a | rest], b, [diag | ups], i, limit) do
    {row, row_min} = lev_row(char_a, b, diag, ups, i, [i], i)

    if row_min > limit,
      do: :over,
      else: lev_rows(rest, b, row, i + 1, limit)
  end

  defp lev_row(_char_a, [], _diag, [], _left, acc, row_min),
    do: {:lists.reverse(acc), row_min}

  defp lev_row(char_a, [char_b | bs], diag, [up | ups], left, acc, row_min) do
    cost = if char_a == char_b, do: 0, else: 1
    value = min(min(left + 1, up + 1), diag + cost)
    lev_row(char_a, bs, up, ups, value, [value | acc], min(row_min, value))
  end

  defp norm(text), do: text |> String.trim() |> String.replace(~r/\s+/u, " ")

  # --- Input shapes ---------------------------------------------------------

  defp thread_location(thread, opts) do
    file_path = field(thread, :file_path) || opts[:file_path]
    side = field(thread, :side) || opts[:side] || "new"
    {file_path, side}
  end

  defp field(%{} = thread, key) do
    case thread do
      %{^key => value} when is_binary(value) -> value
      %{} -> Map.get(thread, Atom.to_string(key))
    end
    |> case do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp thread_anchor(%{anchor: anchor}) when is_map(anchor), do: anchor
  defp thread_anchor(%{"anchor" => anchor}) when is_map(anchor), do: anchor
  defp thread_anchor(anchor) when is_map(anchor), do: anchor
end
