defmodule ReviewsWeb.Api.PatchsetController do
  @moduledoc """
  CLI-facing `/api/v1/reviews/:slug/patchsets` endpoint.

  `POST` appends a new patchset to an existing review and returns the new
  patchset number. Requires a bearer token belonging to the review owner's
  account (human or agent identity). Link access alone does not allow uploads.
  """
  use ReviewsWeb, :controller

  alias Reviews.Reviews

  @doc "POST /api/v1/reviews/:slug/patchsets"
  def create(conn, %{"slug" => slug} = params) do
    case Reviews.get_review_by_slug(slug) do
      nil ->
        conn |> put_status(:not_found) |> json(%{errors: %{detail: "Review not found"}})

      review ->
        attrs = %{
          base_sha: params["base_sha"],
          branch_name: params["branch_name"],
          raw_diff: params["raw_diff"],
          packet: params["packet"]
        }

        case Reviews.append_patchset(review, conn.assigns.current_identity, attrs) do
          {:ok, patchset} ->
            conn
            |> put_status(:created)
            |> json(%{
              patchset_number: patchset.number,
              url: url(~p"/r/#{review.slug}")
            })

          {:error, :forbidden} ->
            conn
            |> put_status(:forbidden)
            |> json(%{errors: %{detail: "Forbidden"}})

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: format_changeset(changeset)})
        end
    end
  end

  defp format_changeset(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
