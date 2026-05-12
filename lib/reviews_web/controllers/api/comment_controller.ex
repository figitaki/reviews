defmodule ReviewsWeb.Api.CommentController do
  @moduledoc """
  CLI-facing `POST /api/v1/reviews/:slug/comments` endpoint. Publishes a
  single comment immediately on behalf of the authenticated user.

  Bearer-token auth via `Plugs.RequireApiToken` (mounted in the router
  pipeline). Accepts both `"line"` and `"token_range"` anchors; the
  token-range relocator across patchsets is still stubbed (`Reviews.Anchoring`),
  matching the v1 contract.
  """
  use ReviewsWeb, :controller

  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads, as: ThreadsContext

  @doc "POST /api/v1/reviews/:slug/comments"
  def create(conn, %{"slug" => slug} = params) do
    author = conn.assigns.current_user

    case ReviewsContext.get_review_by_slug(slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "Review not found"}})

      review ->
        case ThreadsContext.publish_comment(review, author, normalize(params)) do
          {:ok, %{thread: thread, comment: comment}} ->
            conn
            |> put_status(:created)
            |> json(%{
              thread_id: thread.id,
              comment_id: comment.id,
              file_path: thread.file_path,
              side: thread.side,
              anchor: thread.anchor,
              url: url(~p"/r/#{review.slug}") <> "#file-" <> file_anchor(thread)
            })

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: %{detail: error_message(reason)}})
        end
    end
  end

  defp normalize(params) when is_map(params) do
    %{
      "file_path" => params["file_path"],
      "side" => params["side"] || "new",
      "body" => params["body"],
      "thread_anchor" => params["thread_anchor"] || %{}
    }
  end

  defp file_anchor(%{file_path: path}) when is_binary(path), do: path
  defp file_anchor(_), do: ""

  defp error_message(:empty_body), do: "body cannot be empty"
  defp error_message(:invalid_side), do: "side must be \"old\" or \"new\""
  defp error_message(:invalid_file_path), do: "file_path is required"
  defp error_message(:invalid_anchor), do: "thread_anchor must include a granularity"

  defp error_message(:unknown_granularity),
    do: "anchor granularity must be \"line\" or \"token_range\""

  defp error_message(other), do: "could not publish: #{inspect(other)}"
end
