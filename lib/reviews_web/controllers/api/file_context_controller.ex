defmodule ReviewsWeb.Api.FileContextController do
  use ReviewsWeb, :controller

  alias Reviews.CodeSnapshots
  alias Reviews.Reviews, as: ReviewsContext

  def show(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with {number, ""} when number > 0 and number <= 2_147_483_647 <-
           Integer.parse(params["number"]),
         {file_id, ""} when file_id > 0 and file_id <= 9_223_372_036_854_775_807 <-
           Integer.parse(params["file_id"]),
         review when not is_nil(review) <- ReviewsContext.get_review_by_slug(params["slug"]),
         {:ok, context} <- CodeSnapshots.file_context(review, number, file_id) do
      json(conn, context)
    else
      {:error, :context_unavailable} ->
        error(conn, 409, "Context was not uploaded for this patchset.")

      {:error, :code_storage_disabled} ->
        error(conn, 409, "Source context is unavailable.")

      {:error, :too_large} ->
        error(conn, 413, "This file is too large to expand.")

      {:error, :not_text} ->
        error(conn, 422, "Context is only available for text files.")

      {:error, :not_found} ->
        error(conn, 404, "File context was not found.")

      {:error, _} ->
        error(conn, 502, "Could not load context. Try again.")

      _ ->
        error(conn, 404, "File context was not found.")
    end
  end

  defp error(conn, status, message), do: conn |> put_status(status) |> json(%{error: message})
end
