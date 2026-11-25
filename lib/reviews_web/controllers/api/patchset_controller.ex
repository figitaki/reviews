defmodule ReviewsWeb.Api.PatchsetController do
  @moduledoc """
  CLI-facing `/api/v1/reviews/:slug/patchsets` endpoint.

  `POST` appends a new patchset to an existing review and returns the new
  patchset number. Requires a bearer token belonging to the review owner's
  account (human or agent identity). Link access alone does not allow uploads.
  An optional `code_snapshot_id` claims a ready code snapshot for the patchset.
  """
  use ReviewsWeb, :controller

  alias Reviews.Reviews
  alias ReviewsWeb.ApiErrors

  @doc "POST /api/v1/reviews/:slug/patchsets"
  def create(conn, %{"slug" => slug} = params) do
    case Reviews.get_review_by_slug(slug) do
      nil ->
        ReviewsWeb.ApiErrors.render(conn, Reviews.not_found_reason(slug))

      review ->
        attrs = %{
          base_sha: params["base_sha"],
          branch_name: params["branch_name"],
          raw_diff: params["raw_diff"],
          packet: params["packet"],
          code_snapshot_id: params["code_snapshot_id"],
          file_attributes: params["file_attributes"]
        }

        case Reviews.append_patchset(review, conn.assigns.current_principal, attrs) do
          {:ok, %{patchset: patchset, code_snapshot: code_snapshot}} ->
            response = %{
              patchset_number: patchset.number,
              url: url(~p"/r/#{review.slug}")
            }

            conn
            |> put_status(:created)
            |> json(maybe_put_code_snapshot(response, code_snapshot))

          {:error, :forbidden} ->
            conn
            |> put_status(:forbidden)
            |> json(ApiErrors.detail(:forbidden, "Forbidden"))

          {:error, {:code_snapshot, code}} ->
            ApiErrors.render(conn, code)

          {:error, reason} ->
            ApiErrors.render(conn, reason)
        end
    end
  end

  defp maybe_put_code_snapshot(response, nil), do: response

  defp maybe_put_code_snapshot(response, {:skipped, code}) do
    Map.put(response, :code_snapshot, %{status: "skipped", code: Atom.to_string(code)})
  end

  defp maybe_put_code_snapshot(response, snapshot) do
    Map.put(response, :code_snapshot, %{id: snapshot.public_id, status: snapshot.status})
  end
end
