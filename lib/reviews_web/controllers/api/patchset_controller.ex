defmodule ReviewsWeb.Api.PatchsetController do
  @moduledoc """
  CLI-facing `/api/v1/reviews/:slug/patchsets` endpoint.

  `POST` appends a new patchset to an existing review and returns the new
  patchset number. Bearer-token auth (any signed-in user can push to any
  review for now — visibility is link-only in v1).
  """
  use ReviewsWeb, :controller

  import ReviewsWeb.Api.ApiHelpers

  alias Reviews.CodeStorage.Errors
  alias Reviews.Reviews

  @doc "POST /api/v1/reviews/:slug/patchsets"
  def create(conn, %{"slug" => slug} = params) do
    case Reviews.get_review_by_slug(slug) do
      nil ->
        error_json(conn, :not_found, "Review not found")

      review ->
        attrs = %{
          base_sha: params["base_sha"],
          branch_name: params["branch_name"],
          raw_diff: params["raw_diff"],
          packet: params["packet"],
          code_snapshot_id: params["code_snapshot_id"]
        }

        identity = conn.assigns.current_identity

        case Reviews.append_patchset(identity, review, attrs) do
          {:ok, %{patchset: patchset, code_snapshot: code_snapshot}} ->
            response = %{
              patchset_number: patchset.number,
              url: url(~p"/r/#{review.slug}")
            }

            conn
            |> put_status(:created)
            |> json(maybe_put_code_snapshot(response, code_snapshot))

          {:error, {:code_snapshot, code}} when is_atom(code) ->
            error_json(conn, Errors.http_status(code), code, Errors.message(code))

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: format_changeset(changeset)})

          {:error, _reason} ->
            error_json(conn, :unprocessable_entity, "Could not append patchset")
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
