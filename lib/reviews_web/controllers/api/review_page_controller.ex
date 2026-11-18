defmodule ReviewsWeb.Api.ReviewPageController do
  @moduledoc "Bounded read endpoints shared by REST and authenticated Poppy sessions."
  use ReviewsWeb, :controller

  alias Reviews.{Paging, ReviewView, Threads}
  alias Reviews.Reviews, as: ReviewsContext
  alias ReviewsWeb.MCP.Budget
  alias ReviewsWeb.Payloads

  def files(conn, params), do: page(conn, params, :files)
  def threads(conn, params), do: page(conn, params, :threads)
  def comments(conn, params), do: page(conn, params, :comments)

  defp page(conn, params, kind) do
    with review when not is_nil(review) <- ReviewsContext.get_review_by_slug(params["slug"]),
         {:ok, limit} <- Paging.limit(params["limit"]),
         {:ok, max_bytes} <- Paging.max_bytes(params["max_bytes"]),
         {:ok, revision} <- revision(params["revision"]),
         true <- is_nil(params["cursor"]) or not is_nil(revision),
         selected when not is_nil(selected) <-
           ReviewsContext.get_patchset_metadata(review, revision),
         scope = scope(kind, review, selected, params),
         {:ok, cursor} <- cursor(params["cursor"], scope),
         {:ok, entries} <- entries(kind, review, selected, cursor, limit, params) do
      header = %{kind => [], slug: review.slug, revision: selected.number, next_cursor: nil}
      room = max_bytes - byte_size(JSON.encode!(header)) - 256
      {items, next} = fit(entries, kind, cursor, room, limit)

      if entries != [] and items == [] do
        invalid(conn, "max_bytes is too small for the next item's metadata")
      else
        json(conn, %{header | kind => items, next_cursor: Paging.encode(scope, position(next))})
      end
    else
      nil -> missing(conn)
      {:error, :not_found} -> missing(conn)
      _ -> invalid(conn, "Invalid pagination parameters; continuation requests require revision")
    end
  end

  defp entries(:files, _review, selected, {offset, 0}, limit, _params) do
    {:ok, ReviewsContext.list_file_summaries(selected, offset, limit + 1)}
  end

  defp entries(:threads, review, selected, {after_id, 0}, limit, params) do
    if params["status"] in [nil, "open", "resolved"] and
         (is_nil(params["path"]) or is_binary(params["path"])) do
      filters = [
        max_origin_number: selected.number,
        status: params["status"],
        path: params["path"]
      ]

      threads = Threads.list_thread_page(review, filters, after_id, limit + 1)
      counts = Threads.comment_counts(Enum.map(threads, & &1.id))

      revisions =
        ReviewsContext.list_patchset_metadata(
          review,
          Enum.map(threads, & &1.originating_patchset_id)
        )

      {:ok,
       ReviewView.project_threads(review, revisions, selected, threads)
       |> Enum.map(fn thread ->
         thread
         |> Payloads.thread()
         |> Map.update!(:line_text, &Budget.cap(&1, 500))
         |> Map.put(:comment_count, Map.get(counts, thread.id, 0))
       end)}
    else
      {:error, :invalid_parameters}
    end
  end

  defp entries(:comments, review, selected, {id, offset}, limit, params) do
    with {:ok, thread} <- Threads.get_review_thread(review, params["thread_id"]),
         [origin] <-
           ReviewsContext.list_patchset_metadata(review, [thread.originating_patchset_id]),
         true <- origin.number <= selected.number do
      comments =
        Threads.list_comment_page(thread.id, if(offset > 0, do: id - 1, else: id), limit + 1)

      case comments do
        [first | _] when offset > 0 ->
          body = first.body || ""

          if first.id == id and offset <= byte_size(body) and
               (offset == byte_size(body) or
                  not match?(<<0b10::2, _::6>>, binary_part(body, offset, 1))),
             do: {:ok, comments},
             else: {:error, :invalid_cursor}

        _ when offset > 0 ->
          {:error, :invalid_cursor}

        _ ->
          {:ok, comments}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp entries(_, _, _, _, _, _), do: {:error, :invalid_parameters}

  defp fit(entries, kind, cursor, room, limit) do
    fit(entries, kind, cursor, room, limit, [])
  end

  defp fit([], _kind, _cursor, _room, _limit, acc), do: {Enum.reverse(acc), nil}
  defp fit(_entries, _kind, cursor, _room, 0, acc), do: {Enum.reverse(acc), cursor}

  defp fit([entry | rest], :comments, {id, offset}, room, limit, acc) do
    offset = if entry.id == id, do: offset, else: 0

    meta =
      entry
      |> Payloads.comment(:bounded)
      |> Map.merge(%{body: "", offset: offset, complete: false})

    available = room - byte_size(JSON.encode!(meta)) - 4
    {body, next_offset} = Budget.fit_text(entry.body || "", offset, max(available, 0))
    item = %{meta | body: body, complete: is_nil(next_offset)}
    cost = byte_size(JSON.encode!(item)) + 1

    cond do
      cost > room or (body == "" and not is_nil(next_offset)) ->
        {Enum.reverse(acc), {id, offset}}

      next_offset ->
        {Enum.reverse([item | acc]), {entry.id, next_offset}}

      true ->
        fit(rest, :comments, {entry.id, 0}, room - cost, limit - 1, [item | acc])
    end
  end

  defp fit([item | rest], kind, {id, 0}, room, limit, acc) do
    cost = byte_size(JSON.encode!(item)) + 1
    next = if kind == :files, do: id + 1, else: item.id

    if cost <= room,
      do: fit(rest, kind, {next, 0}, room - cost, limit - 1, [item | acc]),
      else: {Enum.reverse(acc), {id, 0}}
  end

  # REST and Poppy share semantics. MCP comment positions use a different
  # ID convention, so their cursors must never enter this namespace.
  defp scope(:files, review, selected, _params),
    do: {:rest_page, :files, review.id, selected.number}

  defp scope(:threads, review, selected, params),
    do: {:rest_page, :threads, review.id, selected.number, params["status"], params["path"]}

  defp scope(:comments, review, selected, params),
    do: {:rest_page, :comments, review.id, selected.number, params["thread_id"]}

  defp cursor(value, scope) do
    case Paging.decode(value, scope) do
      {:ok, nil} -> {:ok, {0, 0}}
      {:ok, {:position, id, offset}} -> {:ok, {id, offset}}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp position(nil), do: nil
  defp position({id, offset}), do: {:position, id, offset}

  # Revision IDs use the database int32 range, independently of page limits.
  defp revision(nil), do: {:ok, nil}

  defp revision(value) when is_binary(value) and byte_size(value) <= 10 do
    case Integer.parse(value) do
      {n, ""} when n >= 1 and n <= 2_147_483_647 -> {:ok, n}
      _ -> {:error, :invalid_parameters}
    end
  end

  defp revision(_), do: {:error, :invalid_parameters}

  defp invalid(conn, detail),
    do:
      conn
      |> put_status(422)
      |> json(%{
        error_code: "invalid_pagination",
        error_detail: detail,
        errors: %{detail: detail}
      })

  defp missing(conn),
    do:
      conn
      |> put_status(404)
      |> json(%{
        error_code: "resource_not_found",
        error_detail: "Review, revision or thread not found",
        errors: %{detail: "Review, revision or thread not found"}
      })
end
