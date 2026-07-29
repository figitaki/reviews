defmodule ReviewsWeb.Api.SectionDecisionController do
  @moduledoc """
  CLI-facing packet-section decision endpoint.
  """
  use ReviewsWeb, :controller

  alias Reviews.PacketSectionDecisions
  alias Reviews.ReviewPacket
  alias Reviews.Reviews, as: ReviewsContext

  @statuses ~w(approved denied ignored)

  def create(conn, %{"slug" => slug, "section_index" => section_index, "status" => status})
      when status in @statuses do
    identity = conn.assigns.current_identity

    with {:ok, section_index} <- parse_section_index(section_index),
         {:ok, review} <- fetch_review(slug),
         {:ok, patchset} <- fetch_latest_patchset(review),
         {:ok, section} <- fetch_section(patchset, section_index),
         patchsets <- ReviewsContext.list_patchsets(review),
         decisions <- PacketSectionDecisions.list_for_review(review, identity),
         {:ok, decision} <-
           PacketSectionDecisions.put_section_status(
             review,
             patchset,
             identity,
             section,
             decisions,
             patchsets,
             status
           ) do
      json(conn, %{
        review: review.slug,
        patchset_number: patchset.number,
        section_index: section_index,
        status: decision && decision.status
      })
    else
      {:error, :invalid_section_index} ->
        conn |> put_status(:bad_request) |> json(%{errors: %{detail: "Invalid section index"}})

      {:error, :review_not_found} ->
        conn |> put_status(:not_found) |> json(%{errors: %{detail: "Review not found"}})

      {:error, :patchset_not_found} ->
        conn |> put_status(:not_found) |> json(%{errors: %{detail: "Patchset not found"}})

      {:error, :section_not_found} ->
        conn |> put_status(:not_found) |> json(%{errors: %{detail: "Section not found"}})

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{detail: "Could not update section decision"}})
    end
  end

  def create(conn, %{"status" => status}) when status not in @statuses do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: "status must be approved, denied, or ignored"}})
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "Invalid request"}})
  end

  defp parse_section_index(value) do
    case Integer.parse(to_string(value)) do
      {index, ""} when index >= 0 -> {:ok, index}
      _ -> {:error, :invalid_section_index}
    end
  end

  defp fetch_review(slug) do
    case ReviewsContext.get_review_by_slug(slug) do
      nil -> {:error, :review_not_found}
      review -> {:ok, review}
    end
  end

  defp fetch_latest_patchset(review) do
    case ReviewsContext.latest_patchset(review) do
      nil -> {:error, :patchset_not_found}
      patchset -> {:ok, patchset}
    end
  end

  defp fetch_section(patchset, section_index) do
    case ReviewPacket.section_at(patchset.packet || %{}, section_index) do
      nil -> {:error, :section_not_found}
      section -> {:ok, section}
    end
  end
end
