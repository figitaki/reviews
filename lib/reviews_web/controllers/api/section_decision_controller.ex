defmodule ReviewsWeb.Api.SectionDecisionController do
  @moduledoc """
  CLI-facing packet-section decision endpoint.
  """
  use ReviewsWeb, :controller

  alias Reviews.PacketSectionDecisions
  alias Reviews.ReviewPacket
  alias Reviews.Reviews, as: ReviewsContext

  @statuses ~w(approved denied ignored pending)

  def create(conn, %{"slug" => slug, "section_index" => section_index, "status" => status})
      when status in @statuses do
    principal = conn.assigns.current_principal

    # An explicit status, not a toggle, so a retried request is harmless.
    with {:ok, section_index} <- parse_section_index(section_index),
         {:ok, review} <- fetch_review(slug),
         {:ok, patchset} <- fetch_latest_patchset(review),
         {:ok, section} <- fetch_section(patchset, section_index),
         {:ok, decision} <-
           PacketSectionDecisions.decide(review, patchset, principal, section, status) do
      json(conn, %{
        review: review.slug,
        patchset_number: patchset.number,
        section_index: section_index,
        status: decision.status
      })
    else
      {:error, :invalid_section_index} ->
        conn
        |> put_status(:bad_request)
        |> json(ReviewsWeb.ApiErrors.detail(:invalid_section_index, "Invalid section index"))

      {:error, reason} when reason in [:review_not_found, :review_deleted] ->
        ReviewsWeb.ApiErrors.render(conn, reason)

      {:error, :patchset_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(ReviewsWeb.ApiErrors.detail(:patchset_not_found, "Patchset not found"))

      {:error, :section_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(ReviewsWeb.ApiErrors.detail(:section_not_found, "Section not found"))

      {:error, :forbidden} ->
        conn
        |> put_status(:forbidden)
        |> json(
          ReviewsWeb.ApiErrors.detail(:forbidden, "Only the review owner can decide sections")
        )

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ReviewsWeb.ApiErrors.detail(:write_failed, "Could not update section decision"))
    end
  end

  def create(conn, %{"status" => status}) when status not in @statuses do
    conn
    |> put_status(:unprocessable_entity)
    |> json(
      ReviewsWeb.ApiErrors.detail(
        :invalid_status,
        "status must be approved, denied, ignored, or pending"
      )
    )
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(ReviewsWeb.ApiErrors.detail(:invalid_request, "Invalid request"))
  end

  defp parse_section_index(value) do
    case Integer.parse(to_string(value)) do
      {index, ""} when index >= 0 -> {:ok, index}
      _ -> {:error, :invalid_section_index}
    end
  end

  defp fetch_review(slug) do
    case ReviewsContext.get_review_by_slug(slug) do
      nil -> {:error, ReviewsContext.not_found_reason(slug)}
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
