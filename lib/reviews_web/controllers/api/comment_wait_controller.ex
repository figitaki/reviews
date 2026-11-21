defmodule ReviewsWeb.Api.CommentWaitController do
  @moduledoc """
  CLI-facing long poll for new comments and replies on one or more reviews,
  used by `reviews wait`. Bearer-token auth via `Plugs.RequireApiToken`; any
  signed-in identity with the links may wait, as for commenting.
  """
  use ReviewsWeb, :controller

  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.Review
  alias Reviews.Threads
  alias ReviewsWeb.MCP.Budget

  @default_wait_seconds 25
  @max_wait_seconds 30
  @max_results 50
  @max_reviews 20
  @max_body_bytes 8_000
  # Postgres bigint; a larger cursor could not name a comment.
  @max_comment_id 9_223_372_036_854_775_807

  @doc """
  GET /api/v1/comments/wait?reviews=slug1,slug2

  Returns at once when the reviews have comments with an id above `since`;
  otherwise holds the request until one is published or `timeout` seconds
  pass (default #{@default_wait_seconds}, at most #{@max_wait_seconds}).
  Without `since` it waits for comments published after the request. Comment
  ids are one sequence across reviews, so one cursor covers all of them.
  """
  def wait(conn, params) do
    with {:ok, slugs} <- slugs(params["reviews"]),
         {:ok, since} <- bounded_int(params["since"], nil, 0, @max_comment_id),
         {:ok, seconds} <-
           bounded_int(params["timeout"], @default_wait_seconds, 0, @max_wait_seconds),
         {:ok, limit} <- bounded_int(params["limit"], @max_results, 1, @max_results),
         {:ok, reviews} <- fetch_reviews(slugs) do
      ids = Enum.map(reviews, & &1.id)
      since = since || Threads.latest_comment_id(ids)
      {:ok, comments} = Threads.wait_for_comments(reviews, since, limit, seconds * 1000)
      slug_by_id = Map.new(reviews, &{&1.id, &1.slug})

      json(conn, %{
        comments: Enum.map(comments, &payload(&1, slug_by_id)),
        cursor: comments |> List.last(%{id: since}) |> Map.fetch!(:id),
        more: length(comments) == limit
      })
    else
      {:error, {:missing, slug}} ->
        reason = ReviewsContext.not_found_reason(slug)

        ReviewsWeb.ApiErrors.render(
          conn,
          reason,
          "Review #{slug}: #{Reviews.Errors.detail(reason)}"
        )

      {:error, :invalid} ->
        ReviewsWeb.ApiErrors.render(
          conn,
          :invalid_request,
          "reviews must list 1-#{@max_reviews} slugs separated by commas; since, " <>
            "timeout and limit must be whole numbers: since 0 or more, " <>
            "timeout 0-#{@max_wait_seconds}, limit 1-#{@max_results}"
        )
    end
  end

  # The fields an agent needs to answer a comment, and nothing larger.
  defp payload(comment, slug_by_id) do
    thread = comment.thread
    body = comment.body || ""

    %{
      review: Map.fetch!(slug_by_id, thread.review_id),
      thread_id: thread.id,
      comment_id: comment.id,
      author: comment.author && Budget.cap(comment.author.handle, 128),
      file_path: thread.file_path,
      line: get_in(thread.anchor || %{}, ["line_number_hint"]),
      body: Budget.cap(body, @max_body_bytes),
      truncated: byte_size(body) > @max_body_bytes
    }
  end

  defp slugs(value) when is_binary(value) and byte_size(value) <= 2_000 do
    slugs = value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.uniq()

    if slugs != [] and length(slugs) <= @max_reviews and "" not in slugs,
      do: {:ok, slugs},
      else: {:error, :invalid}
  end

  defp slugs(_value), do: {:error, :invalid}

  defp fetch_reviews(slugs) do
    Enum.reduce_while(slugs, {:ok, []}, fn slug, {:ok, acc} ->
      case ReviewsContext.get_review_by_slug(slug) do
        %Review{} = review -> {:cont, {:ok, [review | acc]}}
        nil -> {:halt, {:error, {:missing, slug}}}
      end
    end)
    |> case do
      {:ok, reviews} -> {:ok, Enum.reverse(reviews)}
      error -> error
    end
  end

  defp bounded_int(nil, default, _min, _max), do: {:ok, default}

  defp bounded_int(value, _default, min, max) when is_binary(value) and byte_size(value) <= 19 do
    case Integer.parse(value) do
      {n, ""} when n >= min and n <= max -> {:ok, n}
      _ -> {:error, :invalid}
    end
  end

  defp bounded_int(_value, _default, _min, _max), do: {:error, :invalid}
end
