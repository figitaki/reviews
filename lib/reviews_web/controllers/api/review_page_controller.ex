defmodule ReviewsWeb.Api.ReviewPageController do
  @moduledoc "Bounded read endpoints shared by REST and authenticated Poppy sessions."
  use ReviewsWeb, :controller

  alias Reviews.{ReviewView, Threads}
  alias Reviews.Reviews, as: ReviewsContext
  alias ReviewsWeb.MCP.Budget
  alias ReviewsWeb.Payloads

  def files(conn, params), do: page(conn, params, :files)
  def threads(conn, params), do: page(conn, params, :threads)
  def comments(conn, params), do: page(conn, params, :comments)

  defp page(conn, params, kind) do
    with review when not is_nil(review) <- ReviewsContext.get_review_by_slug(params["slug"]),
         {:ok, limit} <- integer(params["limit"], 25, 1, 100),
         {:ok, max_bytes} <- integer(params["max_bytes"], 40_000, 2_000, 120_000),
         {:ok, revision} <- integer(params["revision"], nil, 1, 2_147_483_647),
         true <- is_nil(params["cursor"]) or not is_nil(revision),
         {:ok, cursor} <- cursor(params["cursor"]),
         revisions = ReviewsContext.list_patchset_summaries(review),
         selected when not is_nil(selected) <- ReviewView.pick_patchset(revisions, revision),
         {:ok, entries} <- entries(kind, review, revisions, selected, cursor, limit, params) do
      header = %{kind => [], slug: review.slug, revision: selected.number, next_cursor: nil}
      room = max_bytes - byte_size(JSON.encode!(header)) - 256
      {items, next} = fit(entries, kind, cursor, room, limit)

      if entries != [] and items == [] do
        invalid(conn, "max_bytes is too small for the next item's metadata")
      else
        json(conn, %{header | kind => items, next_cursor: next})
      end
    else
      nil -> missing(conn)
      {:error, :not_found} -> missing(conn)
      _ -> invalid(conn, "Invalid pagination parameters; continuation requests require revision")
    end
  end

  defp entries(:files, _review, _revisions, selected, {offset, 0}, limit, _params) do
    {:ok, ReviewsContext.list_file_summaries(selected, offset, limit + 1)}
  end

  defp entries(:threads, review, revisions, selected, {after_id, 0}, limit, params) do
    if params["status"] in [nil, "open", "resolved"] and
         (is_nil(params["path"]) or is_binary(params["path"])) do
      filters = [
        max_origin_number: selected.number,
        status: params["status"],
        path: params["path"]
      ]

      threads = Threads.list_thread_page(review, filters, after_id, limit + 1)
      counts = Threads.comment_counts(Enum.map(threads, & &1.id))

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

  defp entries(:comments, review, revisions, selected, {id, offset}, limit, params) do
    with {:ok, thread} <- Threads.get_review_thread(review, params["thread_id"]),
         origin when not is_nil(origin) <-
           Enum.find(revisions, &(&1.id == thread.originating_patchset_id)),
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

  defp entries(_, _, _, _, _, _, _), do: {:error, :invalid_parameters}

  defp fit(entries, kind, cursor, room, limit) do
    fit(entries, kind, cursor, room, limit, [])
  end

  defp fit([], _kind, _cursor, _room, _limit, acc), do: {Enum.reverse(acc), nil}
  defp fit(_entries, _kind, cursor, _room, 0, acc), do: {Enum.reverse(acc), encode(cursor)}

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
        {Enum.reverse(acc), encode({id, offset})}

      next_offset ->
        {Enum.reverse([item | acc]), encode({entry.id, next_offset})}

      true ->
        fit(rest, :comments, {entry.id, 0}, room - cost, limit - 1, [item | acc])
    end
  end

  defp fit([item | rest], kind, {id, 0}, room, limit, acc) do
    cost = byte_size(JSON.encode!(item)) + 1
    next = if kind == :files, do: id + 1, else: item.id

    if cost <= room,
      do: fit(rest, kind, {next, 0}, room - cost, limit - 1, [item | acc]),
      else: {Enum.reverse(acc), encode({id, 0})}
  end

  defp cursor(nil), do: {:ok, {0, 0}}

  defp cursor(value) when is_binary(value) and byte_size(value) <= 42 do
    case Regex.run(~r/\Ac(\d{1,18})\.(\d{1,18})\z/, value) do
      [_, id, offset] -> {:ok, {String.to_integer(id), String.to_integer(offset)}}
      _ -> {:error, :invalid_cursor}
    end
  end

  defp cursor(_), do: {:error, :invalid_cursor}
  defp encode({id, offset}), do: "c#{id}.#{offset}"

  defp integer(nil, default, _min, _max), do: {:ok, default}

  defp integer(value, _default, min, max) when is_binary(value) and byte_size(value) <= 18 do
    case Integer.parse(value) do
      {n, ""} when n >= min and n <= max -> {:ok, n}
      _ -> {:error, :invalid_parameters}
    end
  end

  defp integer(_, _, _, _), do: {:error, :invalid_parameters}

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
