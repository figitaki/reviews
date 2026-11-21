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
  alias Reviews.Reviews.Review
  alias Reviews.Threads, as: ThreadsContext

  @doc "POST /api/v1/reviews/:slug/comments"
  def create(conn, %{"slug" => slug} = params) do
    principal = conn.assigns.current_principal

    case ReviewsContext.get_review_by_slug(slug) do
      nil ->
        ReviewsWeb.ApiErrors.render(conn, ReviewsContext.not_found_reason(slug))

      review ->
        case ThreadsContext.publish_comment(review, principal, normalize(params)) do
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

          {:error, :forbidden} ->
            conn
            |> put_status(:forbidden)
            |> json(%{errors: %{detail: "You cannot comment on this review"}})

          {:error, :thread_not_found} ->
            ReviewsWeb.ApiErrors.render(conn, :thread_not_found)

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(
              ReviewsWeb.ApiErrors.detail(
                ReviewsWeb.ApiErrors.code(reason),
                error_message(reason)
              )
            )
        end
    end
  end

  @default_wait_seconds 25
  @max_wait_seconds 30
  @max_wait_results 50
  # Postgres bigint; a larger cursor could not name a comment.
  @max_comment_id 9_223_372_036_854_775_807

  @doc """
  GET /api/v1/reviews/:slug/comments/wait

  Long poll for new comments and replies. Returns at once when the review has
  comments with an id above `since`; otherwise holds the request until one is
  published or `timeout` seconds pass (default #{@default_wait_seconds}, at most
  #{@max_wait_seconds}). Without `since` it waits for comments published after
  the request. The response's `cursor` is the `since` for the next call.
  """
  def wait(conn, %{"slug" => slug} = params) do
    with {:ok, since} <- bounded_int(params["since"], nil, 0, @max_comment_id),
         {:ok, seconds} <-
           bounded_int(params["timeout"], @default_wait_seconds, 0, @max_wait_seconds),
         {:ok, limit} <- bounded_int(params["limit"], @max_wait_results, 1, @max_wait_results),
         %Review{} = review <- ReviewsContext.get_review_by_slug(slug) do
      since = since || ThreadsContext.latest_comment_id(review)
      {:ok, comments} = ThreadsContext.wait_for_comments(review, since, limit, seconds * 1000)

      json(conn, %{
        comments: Enum.map(comments, &wait_payload/1),
        cursor: comments |> List.last(%{id: since}) |> Map.fetch!(:id),
        more: length(comments) == limit
      })
    else
      nil ->
        ReviewsWeb.ApiErrors.render(conn, ReviewsContext.not_found_reason(slug))

      {:error, :invalid} ->
        ReviewsWeb.ApiErrors.render(
          conn,
          :invalid_request,
          "since, timeout and limit must be whole numbers: since 0 or more, " <>
            "timeout 0-#{@max_wait_seconds}, limit 1-#{@max_wait_results}"
        )
    end
  end

  defp wait_payload(comment) do
    comment
    |> ReviewsWeb.Payloads.comment(:bounded)
    |> Map.merge(%{
      thread_id: comment.thread.id,
      file_path: comment.thread.file_path,
      side: comment.thread.side,
      line: get_in(comment.thread.anchor || %{}, ["line_number_hint"]),
      thread_status: comment.thread.status
    })
  end

  defp bounded_int(nil, default, _min, _max), do: {:ok, default}

  defp bounded_int(value, _default, min, max) when is_binary(value) and byte_size(value) <= 19 do
    case Integer.parse(value) do
      {n, ""} when n >= min and n <= max -> {:ok, n}
      _ -> {:error, :invalid}
    end
  end

  defp bounded_int(_value, _default, _min, _max), do: {:error, :invalid}

  defp normalize(params) when is_map(params) do
    %{
      "file_path" => params["file_path"],
      "side" => params["side"] || "new",
      "body" => params["body"],
      "thread_anchor" => params["thread_anchor"] || %{},
      # Passed through as given. `publish_comment/3` casts it and returns
      # `:thread_not_found` when it is not a thread of this review.
      "thread_id" => params["thread_id"],
      "revision" => params["revision"],
      "originating_patchset_id" => params["originating_patchset_id"]
    }
  end

  defp file_anchor(%{file_path: path}) when is_binary(path), do: path
  defp file_anchor(_), do: ""

  defp error_message(:empty_body), do: "body cannot be empty"
  defp error_message(:invalid_side), do: "side must be \"old\" or \"new\""
  defp error_message(:invalid_file_path), do: "file_path is required"

  defp error_message(:invalid_anchor),
    do: "thread_anchor must identify a line and valid token selection in the selected revision"

  defp error_message(:patchset_not_found),
    do:
      "revision must identify a patchset of this review; supply revision or originating_patchset_id, not both"

  defp error_message(:unknown_granularity),
    do: "anchor granularity must be \"line\" or \"token_range\""

  defp error_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
  end

  defp error_message(_other), do: "could not publish comment"
end
