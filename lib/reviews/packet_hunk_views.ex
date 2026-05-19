defmodule Reviews.PacketHunkViews do
  @moduledoc """
  Persistence helpers for per-reviewer hunk viewed state.
  """
  import Ecto.Query, warn: false

  alias Reviews.Accounts.User
  alias Reviews.Repo
  alias Reviews.Reviews.{PacketHunkView, Patchset, Review}

  def list_for_review(%Review{id: review_id}, %User{id: author_id}) do
    PacketHunkView
    |> where([v], v.review_id == ^review_id and v.author_id == ^author_id)
    |> order_by([v], asc: v.file_path, asc: v.hunk_index, asc: v.inserted_at)
    |> Repo.all()
  end

  def list_for_review(_review, nil), do: []

  def mark_viewed(%Review{} = review, %Patchset{} = patchset, %User{} = author, attrs) do
    base_attrs =
      attrs
      |> Map.take([
        :file_path,
        :row_ref,
        :hunk_fingerprint,
        :hunk_index,
        :line_start,
        :line_end,
        :section_index,
        :section_title
      ])
      |> Map.merge(%{
        review_id: review.id,
        patchset_id: patchset.id,
        author_id: author.id
      })

    %PacketHunkView{}
    |> PacketHunkView.changeset(base_attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :patchset_id,
           :hunk_index,
           :line_start,
           :line_end,
           :section_index,
           :section_title,
           :updated_at
         ]},
      conflict_target: [:review_id, :author_id, :file_path, :row_ref, :hunk_fingerprint]
    )
  end

  def clear_viewed(%Review{} = review, %User{} = author, attrs) do
    case Repo.get_by(PacketHunkView,
           review_id: review.id,
           author_id: author.id,
           file_path: attrs.file_path,
           row_ref: attrs.row_ref,
           hunk_fingerprint: attrs.hunk_fingerprint
         ) do
      nil -> {:ok, nil}
      %PacketHunkView{} = view -> Repo.delete(view)
    end
  end

  def viewed?(views, hunk) when is_list(views) do
    key = view_key(hunk)

    Enum.any?(views, fn view ->
      view_key(view) == key
    end)
  end

  def view_key(%{file_path: file_path, row_ref: row_ref, hunk_fingerprint: hunk_fingerprint}) do
    {file_path, row_ref, hunk_fingerprint}
  end

  def view_key(%PacketHunkView{} = view) do
    {view.file_path, view.row_ref, view.hunk_fingerprint}
  end
end
