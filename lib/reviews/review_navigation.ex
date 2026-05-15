defmodule Reviews.ReviewNavigation do
  @moduledoc """
  Derived read-model helpers for review rounds, turns, packets, and diff stats.

  Patchsets remain the persisted primitive. A packet-bearing patchset starts a
  derived round, and later patchsets are turns inside that round.
  """

  alias Reviews.{ReviewPacket, Reviews}

  def build(patchsets, selected_patchset) do
    rounds = rounds(patchsets)
    selected_number = selected_patchset && selected_patchset.number

    current_round =
      Enum.find(rounds, &Enum.any?(&1.turns, fn t -> t.number == selected_number end))

    current_round = current_round || List.last(rounds) || empty_round()
    current_round_index = Enum.find_index(rounds, &(&1.index == current_round.index)) || 0

    selected_turn_index =
      Enum.find_index(current_round.turns, &(&1.number == selected_number)) || 0

    %{
      rounds: rounds,
      round_count: length(rounds),
      current_round: current_round,
      selected_turn_index: selected_turn_index + 1,
      previous_round: at_index(rounds, current_round_index - 1),
      next_round: Enum.at(rounds, current_round_index + 1),
      previous_turn: at_index(current_round.turns, selected_turn_index - 1),
      next_turn: Enum.at(current_round.turns, selected_turn_index + 1)
    }
  end

  def rounds([]), do: []

  def rounds(patchsets) do
    patchsets
    |> Enum.reduce([], fn patchset, rounds ->
      turn = patchset_turn(patchset)

      cond do
        rounds == [] ->
          [new_round(1, turn, patchset)]

        ReviewPacket.present?(patchset.packet) ->
          [new_round(length(rounds) + 1, turn, patchset) | rounds]

        true ->
          [round | rest] = rounds

          [
            %{
              round
              | turns: [turn | round.turns],
                end_number: turn.number,
                turn_count: round.turn_count + 1
            }
            | rest
          ]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn round -> %{round | turns: Enum.reverse(round.turns)} end)
  end

  def patchset_stats(%{raw_diff: raw_diff}) do
    raw_diff
    |> Reviews.parse_diff_files()
    |> diff_stats_from_files()
  end

  def diff_stats_from_files(file_diffs) do
    Enum.reduce(file_diffs, %{files: 0, additions: 0, deletions: 0}, fn file, acc ->
      %{
        files: acc.files + 1,
        additions: acc.additions + Map.get(file, :additions, 0),
        deletions: acc.deletions + Map.get(file, :deletions, 0)
      }
    end)
  end

  def format_diff_stats(%{files: files, additions: additions, deletions: deletions}) do
    "#{files} #{plural(files, "file")} · +#{additions} -#{deletions}"
  end

  defp patchset_turn(patchset) do
    %{
      number: patchset.number,
      packet_present: ReviewPacket.present?(patchset.packet),
      stats: patchset_stats(patchset)
    }
  end

  defp new_round(index, turn, patchset) do
    %{
      index: index,
      title: round_title(patchset, index),
      start_number: turn.number,
      end_number: turn.number,
      turn_count: 1,
      turns: [turn]
    }
  end

  defp empty_round do
    %{index: 1, title: "Round 1", start_number: nil, end_number: nil, turn_count: 0, turns: []}
  end

  defp round_title(patchset, index) do
    case ReviewPacket.text(patchset.packet, "title") do
      "" -> "Round #{index}"
      title -> title
    end
  end

  defp at_index(_items, index) when index < 0, do: nil
  defp at_index(items, index), do: Enum.at(items, index)

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
