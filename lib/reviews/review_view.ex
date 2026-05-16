defmodule Reviews.ReviewView do
  @moduledoc """
  Read models for the review screen and review JSON API.

  Persistence remains owned by the `Reviews.Reviews` and `Reviews.Threads`
  contexts. This module assembles the shared view of a review so LiveViews and
  controllers do not duplicate file/thread payload shaping.
  """

  alias Reviews.Accounts.User
  alias Reviews.PacketSectionDecisions
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.{File, Patchset, Review}
  alias Reviews.Threads

  @type snapshot :: %{
          review: Review.t(),
          patchsets: [Patchset.t()],
          selected_patchset: Patchset.t() | nil,
          files: [File.t()],
          file_diffs: [map()],
          packet_section_decisions: [map()],
          published_threads: [map()],
          drafts: [map()],
          viewer: User.t() | nil
        }

  def get_snapshot_by_slug(slug, viewer, opts \\ []) when is_binary(slug) do
    case ReviewsContext.get_review_by_slug(slug) do
      nil -> {:error, :not_found}
      %Review{} = review -> snapshot(review, viewer, opts)
    end
  end

  def snapshot(%Review{} = review, viewer, opts \\ []) do
    patchsets = ReviewsContext.list_patchsets(review)
    selected = pick_patchset(patchsets, Keyword.get(opts, :patchset_number))

    cond do
      patchsets == [] ->
        {:ok, build_snapshot(review, patchsets, nil, [], viewer)}

      selected == nil ->
        {:error, :patchset_not_found}

      true ->
        files = ReviewsContext.list_files(selected)
        {:ok, build_snapshot(review, patchsets, selected, files, viewer)}
    end
  end

  def pick_patchset([], _), do: nil
  def pick_patchset(patchsets, nil), do: List.last(patchsets)
  def pick_patchset(patchsets, number), do: Enum.find(patchsets, &(&1.number == number))

  def file_payloads(%{file_diffs: file_diffs}), do: file_diffs

  def thread_payloads_for_file(%{published_threads: threads}, file_path) do
    threads
    |> Enum.filter(&(&1.file_path == file_path))
    |> Enum.map(&thread_to_payload/1)
  end

  def draft_payloads_for_file(%{drafts: drafts, viewer: viewer}, file_path) do
    drafts
    |> Enum.filter(&(&1.thread.file_path == file_path))
    |> Enum.map(&draft_to_payload(&1, viewer))
  end

  @doc """
  Status:"open" published threads grouped by their OP (the author of the first
  comment), sorted by OP username. Used by the sidebar Open Threads section.
  """
  def open_threads_by_op(%{published_threads: threads}) do
    threads
    |> Enum.filter(&(&1.status == "open"))
    |> Enum.group_by(fn t -> Map.get(List.first(t.comments) || %{}, :author) end)
    |> Enum.sort_by(fn {op, _} -> (op && op.username) || "" end)
  end

  @doc """
  Truncated body of the first comment on a thread, for sidebar previews.
  """
  def first_comment_snippet(thread, limit \\ 120) do
    body =
      (List.first(thread.comments) || %{})
      |> Map.get(:body, "")
      |> to_string()
      |> String.trim()

    if String.length(body) > limit do
      String.slice(body, 0, limit) <> "…"
    else
      body
    end
  end

  defp build_snapshot(review, patchsets, selected, files, viewer) do
    %{
      review: review,
      patchsets: patchsets,
      selected_patchset: selected,
      files: files,
      file_diffs: file_diff_meta(files, selected),
      packet_section_decisions: PacketSectionDecisions.list_for_review(review, viewer),
      published_threads: Threads.list_published_threads(review.id),
      drafts: list_drafts(review, viewer),
      viewer: viewer
    }
  end

  defp list_drafts(_review, nil), do: []
  defp list_drafts(review, %User{} = viewer), do: Threads.list_drafts_for(review, viewer)

  defp file_diff_meta(_files, nil), do: []

  defp file_diff_meta(files, %Patchset{} = selected_patchset) do
    Enum.map(files, fn file ->
      raw_for_file =
        if file.raw_diff in [nil, ""] do
          ReviewsContext.raw_diff_for_file(selected_patchset, file.path) || ""
        else
          file.raw_diff
        end

      {additions, deletions} = file_change_counts(file, raw_for_file)

      Map.merge(file_to_map(file), %{
        additions: additions,
        deletions: deletions,
        raw_diff: raw_for_file
      })
    end)
  end

  defp file_change_counts(%File{additions: additions, deletions: deletions}, _raw_for_file)
       when (is_integer(additions) and additions > 0) or
              (is_integer(deletions) and deletions > 0) do
    {additions || 0, deletions || 0}
  end

  defp file_change_counts(%File{additions: additions, deletions: deletions}, raw_for_file) do
    case ReviewsContext.parse_diff_files(raw_for_file) do
      [%{additions: parsed_additions, deletions: parsed_deletions} | _] ->
        {parsed_additions, parsed_deletions}

      _ ->
        {additions || 0, deletions || 0}
    end
  end

  defp file_to_map(file) do
    %{
      id: file.id,
      path: file.path,
      old_path: file.old_path,
      status: file.status
    }
  end

  defp thread_to_payload(thread) do
    %{
      id: thread.id,
      file_path: thread.file_path,
      side: thread.side,
      anchor: thread.anchor,
      status: thread.status,
      inserted_at: encode_dt(thread.inserted_at),
      author: user_to_payload(thread.author),
      comments:
        Enum.map(thread.comments || [], fn c ->
          %{
            id: c.id,
            body: c.body,
            author: user_to_payload(c.author),
            inserted_at: encode_dt(c.inserted_at),
            updated_at: encode_dt(c.updated_at)
          }
        end)
    }
  end

  defp draft_to_payload(%{thread: thread, comment: comment}, viewer) do
    %{
      id: comment.id,
      thread_id: thread.id,
      file_path: thread.file_path,
      side: thread.side,
      anchor: thread.anchor,
      body: comment.body,
      author: user_to_payload(viewer),
      inserted_at: encode_dt(comment.inserted_at),
      updated_at: encode_dt(comment.updated_at)
    }
  end

  defp user_to_payload(%{id: id, username: username} = u),
    do: %{id: id, username: username, avatar_url: Map.get(u, :avatar_url)}

  defp user_to_payload(_), do: nil

  defp encode_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_dt(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp encode_dt(_), do: nil
end
