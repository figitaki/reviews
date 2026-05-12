defmodule ReviewsWeb.Api.ReviewController do
  @moduledoc """
  CLI-facing `/api/v1/reviews` endpoint.

  `POST` creates a new review along with patchset #1 and returns the URL the
  user should open. Bearer-token auth via `Plugs.RequireApiToken` (mounted
  in the router pipeline).
  """
  use ReviewsWeb, :controller

  alias Reviews.Reviews

  @doc "POST /api/v1/reviews"
  def create(conn, params) do
    author = conn.assigns.current_user

    with %{} = attrs <- normalize_params(params),
         {:ok, %{review: review, patchset: patchset}} <-
           Reviews.create_review_with_initial_patchset(author, attrs) do
      conn
      |> put_status(:created)
      |> json(%{
        id: review.id,
        slug: review.slug,
        url: url(~p"/r/#{review.slug}"),
        patchset_number: patchset.number
      })
    else
      {:error, _step, changeset, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_changeset(changeset)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_changeset(changeset)})

      _ ->
        conn |> put_status(:bad_request) |> json(%{errors: %{detail: "Invalid request"}})
    end
  end

  defp normalize_params(params) when is_map(params) do
    %{
      title: params["title"],
      description: params["description"],
      base_sha: params["base_sha"],
      branch_name: params["branch_name"],
      raw_diff: params["raw_diff"]
    }
  end

  defp normalize_params(_), do: nil

  defp format_changeset(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
