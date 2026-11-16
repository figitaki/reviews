defmodule ReviewsWeb.MCP.Budget do
  @moduledoc """
  Byte accounting for MCP tool results.

  A tool result carries its structured content twice: once as JSON, and once
  as that JSON encoded again inside a text block. `cost/1` counts both, so a
  page assembled within a budget stays within it on the wire. `@envelope`
  reserves room for the JSON-RPC envelope, `_meta`, and a continuation cursor.
  """

  @envelope 1_000

  @doc "Bytes left for list items and text once `header` is in the response."
  def available(max_bytes, header), do: max_bytes - @envelope - cost(header)

  def cost(term) do
    encoded = JSON.encode!(term)
    byte_size(encoded) + byte_size(JSON.encode!(encoded))
  end

  @doc """
  Renders items in order while they fit in `left`. Returns
  `{rendered, left, count}`; `count` is how many items were taken.
  """
  def fill(items, left, render) do
    {taken, left, count} =
      Enum.reduce_while(items, {[], left, 0}, fn item, {acc, left, count} ->
        rendered = render.(item)
        item_cost = cost(rendered) + 4

        if item_cost <= left,
          do: {:cont, {[rendered | acc], left - item_cost, count + 1}},
          else: {:halt, {acc, left, count}}
      end)

    {Enum.reverse(taken), left, count}
  end

  @doc """
  Continues `text` from `offset` (or `:done`), spending at most `cap` of
  `left`. Returns `{chunk, next_offset_or_done, left}`.
  """
  def stream_text(_text, :done, left, _cap), do: {"", :done, left}

  def stream_text(text, offset, left, cap) when is_integer(offset) do
    {chunk, next} = fit_text(text || "", offset, min(left, cap))
    {chunk, next || :done, left - cost(chunk)}
  end

  @doc """
  The longest piece of `text` from `offset` whose cost fits `budget`. It never
  splits a UTF-8 sequence and prefers to end on a line break. Returns
  `{chunk, next_offset}`, with `nil` when the chunk reaches the end. When not
  even one character fits, the chunk is empty and `next_offset` is `offset`.
  """
  def fit_text(text, offset, budget) do
    rest = binary_part(text, offset, byte_size(text) - offset)

    if cost(rest) <= budget,
      do: {rest, nil},
      else: shrink(rest, offset, budget, div(budget, 2))
  end

  defp shrink(_rest, offset, _budget, max) when max <= 0, do: {"", offset}

  defp shrink(rest, offset, budget, max) do
    cut = utf8_cut(rest, max)
    chunk_cost = cost(binary_part(rest, 0, cut))

    if chunk_cost <= budget do
      cut = line_cut(rest, cut)
      {binary_part(rest, 0, cut), offset + cut}
    else
      shrink(rest, offset, budget, min(max - 1, div(max * budget, chunk_cost)))
    end
  end

  @doc "Shortens `text` to at most `max` bytes, marking the cut with an ellipsis."
  def cap(text, _max) when not is_binary(text), do: nil
  def cap(text, max) when byte_size(text) <= max, do: text
  def cap(text, max), do: binary_part(text, 0, utf8_cut(text, max - 3)) <> "…"

  defp utf8_cut(binary, cut) when cut >= byte_size(binary), do: byte_size(binary)
  defp utf8_cut(_binary, cut) when cut <= 0, do: 0

  defp utf8_cut(binary, cut) do
    if match?(<<0b10::2, _::6>>, binary_part(binary, cut, 1)),
      do: utf8_cut(binary, cut - 1),
      else: cut
  end

  defp line_cut(_binary, 0), do: 0

  defp line_cut(binary, cut) do
    case :binary.matches(binary, "\n", scope: {0, cut}) do
      [] ->
        cut

      matches ->
        {pos, 1} = List.last(matches)
        if pos + 1 >= div(cut, 2), do: pos + 1, else: cut
    end
  end
end
