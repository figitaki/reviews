defmodule Reviews.ReviewNavigation do
  @moduledoc """
  Derived read-model helpers for review revisions, packets, and diff stats.

  Patchsets remain the persisted primitive. The UI presents them as linear
  revisions so each update is a new view over the diff, while packet presence
  stays metadata on that revision.
  """

  alias Reviews.{ReviewPacket, Reviews}

  def build(patchsets, selected_patchset) do
    revisions = Enum.map(patchsets, &revision/1)
    selected_number = selected_patchset && selected_patchset.number

    selected_index =
      Enum.find_index(revisions, &(&1.number == selected_number)) ||
        default_revision_index(revisions)

    %{
      revisions: revisions,
      revision_count: length(revisions),
      current_revision: Enum.at(revisions, selected_index) || empty_revision(),
      selected_index: selected_index + 1,
      previous_revision: at_index(revisions, selected_index - 1),
      next_revision: Enum.at(revisions, selected_index + 1)
    }
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

  defp revision(patchset) do
    %{
      number: patchset.number,
      packet_present: ReviewPacket.present?(patchset.packet),
      stats: patchset_stats(patchset)
    }
  end

  defp empty_revision, do: %{number: nil, packet_present: false, stats: empty_stats()}

  defp empty_stats, do: %{files: 0, additions: 0, deletions: 0}

  defp default_revision_index([]), do: 0
  defp default_revision_index(revisions), do: length(revisions) - 1

  defp at_index(_items, index) when index < 0, do: nil
  defp at_index(items, index), do: Enum.at(items, index)

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"
end
