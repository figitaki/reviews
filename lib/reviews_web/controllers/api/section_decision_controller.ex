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

    with {section_index, ""} <- Integer.parse(to_string(section_index)),
         review when not is_nil(review) <- ReviewsContext.get_review_by_slug(slug),
         patchset when not is_nil(patchset) <- ReviewsContext.latest_patchset(review),
         %{} = section <- ReviewPacket.section_at(patchset.packet || %{}, section_index),
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
      nil ->
        conn |> put_status(:not_found) |> json(%{errors: %{detail: "Review not found"}})

      :error ->
        conn |> put_status(:bad_request) |> json(%{errors: %{detail: "Invalid section index"}})

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
end
