defmodule Reviews.Anchoring do
  @moduledoc """
  Pure functions for relocating a `Threads.Thread` across patchsets.

  Dispatches on `thread.anchor["granularity"]`:

    * `"line"`        — line-level anchor. v1 ships this; a real implementation
                        will match `line_text` and disambiguate via
                        `context_before`/`context_after`. For Stream 1 we
                        return `{:ok, anchor}` unchanged as a placeholder.
    * `"token_range"` — token-level anchor. Schema reserved for v1.5. Returns
                        `{:error, :not_implemented}` — locks the dispatch in.

  Any other granularity returns `{:error, :unknown_granularity}`.

  This module is intentionally **pure** — no Ecto, no Repo. The caller (a
  background job, to be written) is responsible for persisting any updated
  anchor or marking the thread `:outdated`.
  """

  @type anchor :: %{required(String.t()) => term()}
  @type result :: {:ok, anchor()} | {:error, atom()}

  @spec relocate(map(), map(), map()) :: result()
  def relocate(thread, old_patchset, new_patchset) do
    anchor = thread_anchor(thread)

    case anchor["granularity"] do
      "line" ->
        relocate_line(anchor, old_patchset, new_patchset)

      "token_range" ->
        # TODO(v1.5): real token-range matching. Plan calls for matching
        # `token_text` within the file and disambiguating by surrounding
        # context. Stream 1 leaves it stubbed.
        {:error, :not_implemented}

      _other ->
        {:error, :unknown_granularity}
    end
  end

  # --- Internal -------------------------------------------------------------

  # Placeholder for the line-level relocation algorithm. The real
  # implementation will:
  #   1. Try an exact match on `line_text` in the new patchset.
  #   2. If multiple matches, disambiguate using `context_before`/`context_after`.
  #   3. If no match, fall back to fuzzy context match.
  #   4. If still nothing, return `{:error, :outdated}` so the caller can mark
  #      the thread.
  # For Stream 1 we just echo the anchor back — wires the contract without
  # implementing the algorithm.
  defp relocate_line(anchor, _old_patchset, _new_patchset) do
    {:ok, anchor}
  end

  defp thread_anchor(%{anchor: anchor}) when is_map(anchor), do: anchor
  defp thread_anchor(%{"anchor" => anchor}) when is_map(anchor), do: anchor
  defp thread_anchor(anchor) when is_map(anchor), do: anchor
end
