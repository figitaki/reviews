defmodule ReviewsWeb.MCP.Handlers do
  @moduledoc """
  Tool, resource, and prompt handlers for `ReviewsWeb.MCP.Server`.

  Every handler resolves the caller from the request's verified principal,
  which `ReviewsWeb.MCP.Server.authenticate/2` derives from an existing Reviews
  API token. Reviews are scoped to the caller's account: the author's human
  identity and its sibling agent identities. Unknown and foreign reviews get
  the same not-found result.

  Every read fits in `max_bytes`, counting metadata and both encodings of the
  result (see `ReviewsWeb.MCP.Budget`). Lists and long text continue with
  `next_cursor` or `next_offset`, which must be sent with the same `revision`.
  Reads load only the rows a page needs, not the whole review.
  """

  alias FastestMCP.Tools.Result
  alias Reviews.{Accounts, Anchoring, ReviewHunks, ReviewPacket, ReviewView}
  alias Reviews.Accounts.Identity
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.Review
  alias Reviews.Threads
  alias ReviewsWeb.MCP.Budget

  @default_max_bytes 40_000
  @min_max_bytes 2_000
  @max_bytes_limit 120_000
  @default_thread_limit 25
  @thread_limit 100
  @title_cap 500
  @path_cap 1_000
  @line_text_cap 500
  @listed_comments 3
  @listed_comment_cap 1_000
  @page_fetch 200
  @feedback_limit 60_000
  @feedback_threads 50
  @feedback_comment_cap 2_000
  @slug_pattern ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @bad_cursor "Invalid cursor. Pass next_cursor from the previous page unchanged."
  @too_small "max_bytes is too small for the next item. Call again with a larger max_bytes."

  def default_max_bytes, do: @default_max_bytes
  def min_max_bytes, do: @min_max_bytes
  def max_bytes_limit, do: @max_bytes_limit
  def thread_limit, do: @thread_limit

  ## Reads

  def whoami(_args, ctx) do
    identity = current_identity!(ctx)
    owner = Accounts.get_user!(identity.owner_user_id)

    %{
      identity: identity_payload(identity),
      account: %{username: owner.username},
      scopes: ctx.verified_scopes || [],
      writes_enabled: ReviewsWeb.MCP.Server.writes_enabled?()
    }
  end

  def get_review(args, ctx) do
    with_review(args, ctx, fn review, _identity ->
      with {:ok, cursor} <- parse_review_cursor(args["cursor"]),
           :ok <- require_pinned_revision(args, args["cursor"]),
           {:ok, revisions, selected} <- select_revision(review, args) do
        packet = ReviewsContext.get_packet(selected)
        counts = Threads.count_by_status(review)

        header = %{
          slug: review.slug,
          title: Budget.cap(review.title, @title_cap),
          url: review_url(review),
          revision: selected.number,
          revision_count: length(revisions),
          latest_revision: List.last(revisions).number,
          threads: %{open: Map.get(counts, "open", 0), resolved: Map.get(counts, "resolved", 0)},
          packet:
            if(ReviewPacket.present?(packet),
              do: %{
                title: Budget.cap(ReviewPacket.text(packet, "title"), @title_cap),
                section_count: length(ReviewPacket.sections(packet))
              }
            ),
          next_cursor: nil
        }

        data = %{
          fields: [
            description: review.description || "",
            packet_summary: ReviewPacket.text(packet, "summary")
          ],
          sections: ReviewPacket.sections(packet),
          revisions: Enum.reverse(revisions)
        }

        left = Budget.available(max_bytes(args), header)
        {body, next} = review_page(cursor, data, left, %{})

        if next && next == encode_review_cursor(cursor) do
          error_result(@too_small)
        else
          header |> Map.merge(body) |> Map.put(:next_cursor, next) |> with_hint(next)
        end
      end
    end)
  end

  def get_packet_section(args, ctx) do
    with_review(args, ctx, fn review, _identity ->
      with {:ok, cursor} <- parse_pair_cursor(args["cursor"]),
           :ok <- require_pinned_revision(args, args["cursor"]),
           {:ok, _revisions, selected} <- select_revision(review, args),
           {:ok, section, count} <- fetch_section(selected, args["section_index"]) do
        paths =
          for row <- section.rows,
              ReviewPacket.text(row, "kind") == "hunk",
              uniq: true,
              do: ReviewPacket.text(row, "path")

        hunks_by_path = selected |> ReviewsContext.list_files(paths) |> ReviewHunks.for_files()

        header = %{
          slug: review.slug,
          revision: selected.number,
          section_index: section.index,
          section_count: count,
          title: Budget.cap(section.title, @title_cap),
          row_count: length(section.rows),
          next_cursor: nil
        }

        start = cursor || {0, 0}
        left = Budget.available(max_bytes(args), header)

        {rows, next} =
          stream_items(
            Enum.with_index(section.rows),
            start,
            left,
            fn {row, index} -> {index, section_row(row, index, hunks_by_path)} end
          )

        if next == start do
          error_result(@too_small)
        else
          next_cursor = encode_pair(next)
          %{header | next_cursor: next_cursor} |> Map.put(:rows, rows) |> with_hint(next_cursor)
        end
      end
    end)
  end

  def list_files(args, ctx) do
    with_review(args, ctx, fn review, _identity ->
      with {:ok, offset} <- parse_int_cursor(args["cursor"]),
           :ok <- require_pinned_revision(args, args["cursor"]),
           {:ok, _revisions, selected} <- select_revision(review, args) do
        offset = offset || 0
        fetched = ReviewsContext.list_file_summaries(selected, offset, @page_fetch + 1)
        open = Threads.open_counts_by_path(review, Enum.map(fetched, & &1.path))

        header = %{
          slug: review.slug,
          revision: selected.number,
          file_count: selected.stats.files,
          next_cursor: nil
        }

        {files, _left, count} =
          Budget.fill(
            Enum.take(fetched, @page_fetch),
            Budget.available(max_bytes(args), header),
            fn file ->
              %{
                file
                | path: Budget.cap(file.path, @path_cap),
                  old_path: Budget.cap(file.old_path, @path_cap)
              }
              |> Map.put(:open_threads, Map.get(open, file.path, 0))
            end
          )

        cond do
          count == 0 and fetched != [] ->
            error_result(@too_small)

          count < length(fetched) ->
            next = Integer.to_string(offset + count)
            %{header | next_cursor: next} |> Map.put(:files, files) |> with_hint(next)

          true ->
            Map.put(header, :files, files)
        end
      end
    end)
  end

  def get_file_diff(args, ctx) do
    with_review(args, ctx, fn review, _identity ->
      offset = args["offset"] || 0

      with :ok <- require_pinned_revision(args, offset > 0),
           {:ok, _revisions, selected} <- select_revision(review, args),
           {:ok, raw} <- file_diff(selected, args["path"]),
           :ok <- valid_offset(raw, offset) do
        header = %{
          slug: review.slug,
          revision: selected.number,
          path: Budget.cap(args["path"], @path_cap),
          offset: offset,
          total_bytes: byte_size(raw),
          next_offset: byte_size(raw)
        }

        case Budget.fit_text(raw, offset, Budget.available(max_bytes(args), header)) do
          {"", ^offset} when offset < byte_size(raw) ->
            error_result(@too_small)

          {chunk, next} ->
            header |> Map.put(:diff, chunk) |> Map.put(:next_offset, next)
        end
      end
    end)
  end

  def list_threads(args, ctx) do
    with_review(args, ctx, fn review, _identity ->
      limit = args["limit"] || @default_thread_limit
      status = args["status"] || "open"

      with {:ok, after_id} <- parse_int_cursor(args["cursor"]),
           :ok <- require_pinned_revision(args, args["cursor"]),
           {:ok, revisions, selected} <- select_revision(review, args) do
        filters = [
          max_origin_number: selected.number,
          status: if(status != "all", do: status),
          path: args["path"]
        ]

        page = Threads.list_thread_page(review, filters, after_id || 0, limit + 1)
        shown = Enum.take(page, limit)
        projected = ReviewView.project_threads(review, revisions, selected, shown)
        comment_counts = Threads.comment_counts(Enum.map(shown, & &1.id))

        header = %{
          slug: review.slug,
          revision: selected.number,
          status: status,
          total: Threads.count_threads(review, filters),
          next_cursor: nil
        }

        {threads, count} =
          fill_threads(projected, comment_counts, Budget.available(max_bytes(args), header))

        cond do
          count == 0 and page != [] ->
            error_result(@too_small)

          count < length(page) ->
            next = Integer.to_string(Enum.at(projected, count - 1).id)
            %{header | next_cursor: next} |> Map.put(:threads, threads) |> with_hint(next)

          true ->
            Map.put(header, :threads, threads)
        end
      end
    end)
  end

  def get_thread(args, ctx) do
    with_review(args, ctx, fn review, _identity ->
      with {:ok, cursor} <- parse_pair_cursor(args["cursor"]),
           :ok <- require_pinned_revision(args, args["cursor"]),
           {:ok, revisions, selected} <- select_revision(review, args),
           {:ok, thread} <- review_thread(review, args["thread_id"]),
           [projected] <- ReviewView.project_threads(review, revisions, selected, [thread]) do
        {start_id, _offset} = start = cursor || {0, 0}
        comments = Threads.list_comment_page(thread.id, start_id - 1, @page_fetch)

        header =
          projected
          |> thread_summary(Threads.comment_counts([thread.id]) |> Map.get(thread.id, 0))
          |> Map.merge(%{slug: review.slug, revision: selected.number, next_cursor: nil})

        {page, next} =
          stream_items(
            Enum.map(comments, &{&1, &1.id}),
            start,
            Budget.available(max_bytes(args), header),
            fn {comment, id} -> {id, comment_parts(comment)} end
          )

        # A full page of comments may have more after it.
        next =
          if is_nil(next) and length(comments) == @page_fetch,
            do: {List.last(comments).id + 1, 0},
            else: next

        if next == start do
          error_result(@too_small)
        else
          next_cursor = encode_pair(next)

          %{header | next_cursor: next_cursor}
          |> Map.put(:comments, page)
          |> with_hint(next_cursor)
        end
      else
        [] -> {:error, "That thread started on a later revision. Omit revision to read it."}
        other -> other
      end
    end)
  end

  ## Writes

  def create_review(args, ctx) do
    ensure_writes_enabled!()
    identity = current_identity!(ctx)

    with :ok <- validate_diff_and_packet(args["raw_diff"], args["packet"]),
         {:ok, %{review: review, patchset: ps}} <-
           ReviewsContext.create_review_with_initial_patchset(identity, push_attrs(args)) do
      %{slug: review.slug, url: review_url(review), revision: ps.number}
    else
      {:error, _step, changeset, _} -> changeset_result(changeset)
      other -> write_error(other)
    end
  end

  def append_revision(args, ctx) do
    ensure_writes_enabled!()

    with_review(args, ctx, fn review, identity ->
      with :ok <- validate_diff_and_packet(args["raw_diff"], args["packet"]),
           {:ok, ps} <- ReviewsContext.append_patchset(review, identity, push_attrs(args)) do
        %{slug: review.slug, url: review_url(review), revision: ps.number}
      else
        other -> write_error(other)
      end
    end)
  end

  def post_comment(args, ctx) do
    ensure_writes_enabled!()

    with_review(args, ctx, fn review, identity ->
      with {:ok, params} <- comment_params(review, args),
           {:ok, %{thread: thread, comment: comment}} <-
             Threads.publish_comment(review, identity, params) do
        %{
          slug: review.slug,
          thread_id: thread.id,
          comment_id: comment.id,
          path: thread.file_path,
          side: thread.side,
          line: thread.anchor["line_number_hint"],
          url: review_url(review)
        }
      else
        {:error, :thread_not_found} ->
          error_result("No thread #{args["thread_id"]} on this review. List threads first.")

        other ->
          write_error(other)
      end
    end)
  end

  def update_thread_status(args, ctx) do
    ensure_writes_enabled!()

    with_review(args, ctx, fn review, identity ->
      case Threads.update_status(review, args["thread_id"], identity, args["status"]) do
        {:ok, thread} ->
          %{
            slug: review.slug,
            thread_id: thread.id,
            status: thread.status,
            resolved_by: identity_payload(thread.resolved_by)
          }

        {:error, :not_found} ->
          error_result("No thread #{args["thread_id"]} on this review. List threads first.")

        other ->
          write_error(other)
      end
    end)
  end

  ## Resources and prompts

  def feedback_markdown(%{"slug" => slug}, ctx) do
    identity = current_identity!(ctx)

    with {:ok, review} <- owned_review(slug, identity),
         {:ok, revisions, latest} <- select_revision(review, %{}) do
      FastestMCP.Resources.Text.new(render_feedback(review, revisions, latest),
        mime_type: "text/markdown"
      )
    else
      _ -> raise FastestMCP.Error, code: :not_found, message: not_found_message(slug)
    end
  end

  def address_feedback_prompt(%{"review" => review}, _ctx) do
    """
    Address the open feedback on the Reviews review "#{review}".

    1. Call reviews_get_review to see the revision, packet outline, and thread counts.
    2. Call reviews_list_threads with status "open". Read each thread with the code it
       points at (reviews_get_file_diff or reviews_get_packet_section), and use
       reviews_get_thread when a thread has more comments than the list shows.
    3. Make the requested changes in the working tree. Do not resolve threads you did
       not address.
    4. Reply on each thread you addressed with reviews_post_comment (pass thread_id),
       saying what changed. Resolve it with reviews_update_thread_status only when the
       reviewer's request is fully handled.
    5. When the code changed, push a new revision with `reviews push --update <slug>`
       or reviews_append_revision.

    Comments publish immediately and cannot be edited. Writes are not retried
    automatically; if a call times out, list threads again before retrying.
    """
  end

  ## Caller and review resolution

  defp current_identity!(%{principal: %{"identity_id" => id}}) when is_integer(id) do
    Accounts.get_identity!(id)
  end

  defp with_review(args, ctx, fun) do
    identity = current_identity!(ctx)

    case owned_review(args["review"], identity) do
      {:ok, review} -> fun.(review, identity) |> unwrap()
      {:error, :not_found} -> error_result(not_found_message(args["review"]))
    end
  end

  defp unwrap({:error, %Result{} = result}), do: result
  defp unwrap(%Result{} = result), do: result
  defp unwrap({:error, :patchset_not_found}), do: error_result("That revision does not exist.")
  defp unwrap({:error, message}) when is_binary(message), do: error_result(message)
  defp unwrap(value), do: value

  defp owned_review(ref, %Identity{} = identity) do
    with {:ok, slug} <- parse_review_ref(ref),
         %Review{} = review <- ReviewsContext.get_review_by_slug(slug),
         true <- ReviewsContext.owned_by?(review, identity) do
      {:ok, review}
    else
      _ -> {:error, :not_found}
    end
  end

  # Accepts a slug or a review URL such as https://host/r/abc123/changes.
  defp parse_review_ref(ref) when is_binary(ref) do
    ref = String.trim(ref)

    slug =
      case Regex.run(~r{/r/([^/?#]+)}, ref) do
        [_, slug] -> slug
        nil -> ref
      end

    if Regex.match?(@slug_pattern, slug), do: {:ok, slug}, else: :error
  end

  defp parse_review_ref(_), do: :error

  defp not_found_message(ref) do
    "No review matching #{inspect(ref)} is owned by this account. MCP access covers reviews " <>
      "pushed by you or your agent identities; check the slug or URL."
  end

  # Revision summaries carry no diffs, so picking a revision costs one query
  # however long the review's history is.
  defp select_revision(review, args) do
    revisions = ReviewsContext.list_patchset_summaries(review)

    selected =
      case args["revision"] do
        nil -> List.last(revisions)
        number -> Enum.find(revisions, &(&1.number == number))
      end

    cond do
      revisions == [] -> {:error, "This review has no revisions."}
      is_nil(selected) -> {:error, :patchset_not_found}
      true -> {:ok, revisions, selected}
    end
  end

  # A continuation must name the revision it continues, so a new push never
  # splices pages from two revisions together.
  defp require_pinned_revision(%{"revision" => n}, _continuing) when is_integer(n), do: :ok
  defp require_pinned_revision(_args, continuing) when continuing in [nil, false], do: :ok

  defp require_pinned_revision(_args, _continuing),
    do: {:error, "Pass the revision returned with the previous page to continue."}

  defp fetch_section(selected, index) do
    packet = ReviewsContext.get_packet(selected)
    sections = ReviewPacket.sections(packet)

    cond do
      not ReviewPacket.present?(packet) ->
        {:error,
         "Revision #{selected.number} has no packet. Use reviews_list_files and reviews_get_file_diff."}

      section = Enum.find(sections, &(&1.index == index)) ->
        {:ok, section, length(sections)}

      true ->
        {:error, "No packet section #{index}. Section indexes start at 0."}
    end
  end

  defp file_diff(selected, path) do
    case ReviewsContext.get_file(selected, path) do
      nil -> {:error, "No file #{inspect(path)} in this revision. Call reviews_list_files."}
      file -> {:ok, file.raw_diff || ""}
    end
  end

  defp review_thread(review, thread_id) do
    case Threads.get_review_thread(review, thread_id) do
      {:ok, thread} -> {:ok, thread}
      {:error, :not_found} -> {:error, "No thread #{thread_id} on this review."}
    end
  end

  defp valid_offset(raw, offset) do
    cond do
      offset > byte_size(raw) ->
        {:error, "offset #{offset} is past the end of the diff."}

      offset > 0 and offset < byte_size(raw) and
          match?(<<0b10::2, _::6>>, binary_part(raw, offset, 1)) ->
        {:error, "offset #{offset} is not a valid position. Use next_offset from the last page."}

      true ->
        :ok
    end
  end

  defp max_bytes(args), do: args["max_bytes"] || @default_max_bytes

  ## Cursors

  defp parse_int_cursor(nil), do: {:ok, nil}

  defp parse_int_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, @bad_cursor}
    end
  end

  defp parse_pair_cursor(nil), do: {:ok, nil}

  defp parse_pair_cursor(cursor) when is_binary(cursor) do
    case Regex.run(~r/\A(\d{1,18})\.(\d{1,18})\z/, cursor) do
      [_, a, b] -> {:ok, {String.to_integer(a), String.to_integer(b)}}
      _ -> {:error, @bad_cursor}
    end
  end

  defp encode_pair(nil), do: nil
  defp encode_pair({a, b}), do: "#{a}.#{b}"

  defp parse_review_cursor(nil), do: {:ok, {:fields, 0, 0}}

  defp parse_review_cursor(cursor) when is_binary(cursor) do
    case Regex.run(~r/\A([fsr])(\d{1,18})(?:\.(\d{1,18}))?\z/, cursor) do
      [_, "f", i, o] -> {:ok, {:fields, String.to_integer(i), String.to_integer(o)}}
      [_, "s", i] -> {:ok, {:sections, String.to_integer(i)}}
      [_, "r", i] -> {:ok, {:revisions, String.to_integer(i)}}
      _ -> {:error, @bad_cursor}
    end
  end

  defp encode_review_cursor({:fields, i, o}), do: "f#{i}.#{o}"
  defp encode_review_cursor({:sections, i}), do: "s#{i}"
  defp encode_review_cursor({:revisions, i}), do: "r#{i}"

  defp with_hint(payload, nil), do: payload

  defp with_hint(payload, _next),
    do: Map.put(payload, :hint, "More follows. Call again with next_cursor and this revision.")

  ## Paging

  # get_review pages through its long text fields, then the packet outline,
  # then the revisions, newest first.
  defp review_page({:fields, index, offset}, data, left, acc) do
    case stream_fields(data.fields, index, offset, left) do
      {out, left, nil} -> review_page({:sections, 0}, data, left, Map.merge(acc, out))
      {out, _left, next} -> {Map.merge(acc, out), encode_review_cursor(next)}
    end
  end

  defp review_page({:sections, index}, data, left, acc) do
    rest = Enum.drop(data.sections, index)

    {sections, left, count} =
      Budget.fill(rest, left, fn section ->
        %{
          index: section.index,
          title: Budget.cap(section.title, @title_cap),
          hunks: length(section.refs)
        }
      end)

    acc = Map.put(acc, :sections, sections)

    if count < length(rest),
      do: {acc, encode_review_cursor({:sections, index + count})},
      else: review_page({:revisions, 0}, data, left, acc)
  end

  defp review_page({:revisions, index}, data, left, acc) do
    rest = Enum.drop(data.revisions, index)

    {revisions, _left, count} =
      Budget.fill(rest, left, fn revision ->
        revision
        |> Map.take([:number, :pushed_at, :base_sha, :packet_present, :stats])
        |> Map.put(:branch_name, Budget.cap(revision.branch_name, 255))
      end)

    acc = Map.put(acc, :revisions, revisions)
    {acc, if(count < length(rest), do: encode_review_cursor({:revisions, index + count}))}
  end

  defp stream_fields(fields, start, offset, left) do
    fields
    |> Enum.with_index()
    |> Enum.drop(start)
    |> Enum.reduce_while({%{}, left, nil}, fn {{key, text}, index}, {acc, left, nil} ->
      from = if index == start, do: offset, else: 0
      {chunk, next, left} = Budget.stream_text(text, from, max(left, 0), max(left, 0))
      acc = Map.put(acc, key, chunk)

      case next do
        :done -> {:cont, {acc, left, nil}}
        next -> {:halt, {acc, left, {:fields, index, next}}}
      end
    end)
  end

  # Streams items that each have metadata and one long text field. `start` is
  # `{key, offset}`: the first item at or after `key` continues its text from
  # `offset`. Returns `{entries, next}`, where `next` is `{key, offset}` of
  # the first byte not returned, or nil when everything was returned.
  defp stream_items(items, {start_key, start_offset}, left, parts) do
    items
    |> Enum.map(parts)
    |> Enum.drop_while(fn {key, _} -> key < start_key end)
    |> Enum.reduce_while({[], left}, fn {key, {meta, text_key, text}}, {acc, left} ->
      from = if key == start_key, do: start_offset, else: 0
      left = left - Budget.cost(meta) - 40
      {chunk, next} = Budget.fit_text(text, from, max(left, 0))

      cond do
        chunk == "" and from < byte_size(text) ->
          {:halt, {Enum.reverse(acc), {key, from}}}

        next ->
          entry = Map.merge(meta, %{text_key => chunk, :offset => from, :complete => false})
          {:halt, {Enum.reverse([entry | acc]), {key, next}}}

        true ->
          entry = Map.merge(meta, %{text_key => chunk, :offset => from, :complete => true})
          {:cont, {[entry | acc], left - Budget.cost(chunk)}}
      end
    end)
    |> case do
      {entries, {_key, _offset} = next} -> {entries, next}
      {entries, _left} -> {Enum.reverse(entries), nil}
    end
  end

  ## Payloads

  defp section_row(row, index, hunks_by_path) do
    case ReviewPacket.text(row, "kind") do
      "hunk" ->
        hunk = ReviewHunks.for_packet_row(hunks_by_path, row)

        meta = %{
          row: index,
          kind: "hunk",
          path: Budget.cap(ReviewPacket.text(row, "path"), @path_cap),
          hunk_index: ReviewPacket.int(row, "hunk_index"),
          line_start: hunk && hunk.line_start,
          line_end: hunk && hunk.line_end,
          missing: is_nil(hunk)
        }

        {meta, :diff, (hunk && hunk.display_raw_diff) || ""}

      kind ->
        {%{row: index, kind: Budget.cap(kind, 50)}, :body, ReviewPacket.text(row, "body")}
    end
  end

  defp comment_parts(comment) do
    meta = %{
      id: comment.id,
      author: identity_payload(comment.author),
      inserted_at: comment.inserted_at
    }

    {meta, :body, comment.body || ""}
  end

  defp thread_summary(thread, comment_count) do
    %{
      id: thread.id,
      path: Budget.cap(thread.file_path, @path_cap),
      side: thread.side,
      line: thread.anchor && thread.anchor["line_number_hint"],
      line_text: Budget.cap(thread.original_anchor["line_text"], @line_text_cap),
      anchor_status: thread.anchor_status,
      originating_revision: thread.originating_patchset_number,
      status: thread.status,
      resolved_by: identity_payload(thread.resolved_by),
      comment_count: comment_count
    }
  end

  # Threads go in whole while they fit. A first thread too big for the page
  # comes with fewer comment previews, so every page makes progress.
  defp fill_threads(threads, comment_counts, left) do
    Enum.reduce_while(threads, {[], 0, left}, fn thread, {acc, count, left} ->
      comment_count = Map.get(comment_counts, thread.id, 0)
      previews = if count == 0, do: @listed_comments..0//-1, else: [@listed_comments]

      fitting =
        Enum.find_value(previews, fn n ->
          item = listed_thread(thread, comment_count, n)
          cost = Budget.cost(item) + 4
          if cost <= left, do: {item, cost}
        end)

      case fitting do
        {item, cost} -> {:cont, {[item | acc], count + 1, left - cost}}
        nil -> {:halt, {acc, count, left}}
      end
    end)
    |> then(fn {acc, count, _left} -> {Enum.reverse(acc), count} end)
  end

  defp listed_thread(thread, comment_count, previews) do
    comments =
      thread.id
      |> Threads.list_comment_page(0, previews)
      |> Enum.map(fn comment ->
        %{
          id: comment.id,
          author: identity_payload(comment.author),
          body: Budget.cap(comment.body, @listed_comment_cap),
          body_truncated: byte_size(comment.body || "") > @listed_comment_cap,
          inserted_at: comment.inserted_at
        }
      end)

    complete =
      comment_count <= length(comments) and not Enum.any?(comments, & &1.body_truncated)

    thread
    |> thread_summary(comment_count)
    |> Map.merge(%{comments: comments, comments_complete: complete})
  end

  defp identity_payload(%Identity{} = identity) do
    %{
      id: identity.id,
      kind: identity.kind,
      handle: identity.handle,
      display_name: identity.display_name
    }
  end

  defp identity_payload(_), do: nil

  defp review_url(review), do: ReviewsWeb.Endpoint.url() <> "/r/" <> review.slug

  # Bounded like the tools: at most @feedback_threads threads and
  # @feedback_limit bytes, with a note naming what was left out.
  defp render_feedback(review, revisions, latest) do
    filters = [max_origin_number: latest.number, status: "open"]
    total = Threads.count_threads(review, filters)
    page = Threads.list_thread_page(review, filters, 0, @feedback_threads)
    threads = ReviewView.project_threads(review, revisions, latest, page)

    header = """
    # Open feedback: #{Budget.cap(review.title, @title_cap)}

    Review: #{review_url(review)} (revision #{latest.number})
    Open threads: #{total}
    """

    {sections, shown, _left} =
      Enum.reduce_while(threads, {[], 0, @feedback_limit - byte_size(header)}, fn thread,
                                                                                  {acc, shown,
                                                                                   left} ->
        text = render_feedback_thread(thread)

        if byte_size(text) <= left,
          do: {:cont, {[text | acc], shown + 1, left - byte_size(text)}},
          else: {:halt, {acc, shown, left}}
      end)

    omitted =
      if shown < total,
        do: [
          "_#{total - shown} more open threads are not shown. Read them with reviews_list_threads._\n"
        ],
        else: []

    Enum.join([header | Enum.reverse(sections)] ++ omitted, "\n")
  end

  defp render_feedback_thread(thread) do
    location =
      case thread.anchor do
        %{"line_number_hint" => line} ->
          "#{Budget.cap(thread.file_path, @path_cap)}:#{line}"

        _ ->
          "#{Budget.cap(thread.file_path, @path_cap)} (outdated, from revision #{thread.originating_patchset_number})"
      end

    comments =
      thread.id
      |> Threads.list_comment_page(0, 20)
      |> Enum.map_join("\n", fn comment ->
        author = comment.author && comment.author.handle
        "- **#{author}**: #{Budget.cap(comment.body, @feedback_comment_cap)}"
      end)

    "## Thread #{thread.id} at `#{location}` (#{thread.side})\n\n#{comments}\n"
  end

  ## Write helpers

  defp ensure_writes_enabled! do
    unless ReviewsWeb.MCP.Server.writes_enabled?() do
      raise FastestMCP.Error, code: :forbidden, message: "Writes are turned off on this server."
    end
  end

  defp push_attrs(args) do
    %{
      title: args["title"],
      description: args["description"],
      raw_diff: args["raw_diff"],
      packet: args["packet"],
      branch_name: args["branch_name"],
      base_sha: args["base_sha"]
    }
  end

  # The CLI checks packets before upload; MCP callers send the JSON directly,
  # so apply the same hunk and slice rules here (cli/src/packet.rs).
  defp validate_diff_and_packet(raw_diff, packet) do
    files = ReviewsContext.parse_diff_files(raw_diff)

    cond do
      files == [] ->
        {:error, "raw_diff has no files. Send the output of `git diff`."}

      is_nil(packet) ->
        :ok

      true ->
        hunks_by_path = ReviewHunks.for_files(files)

        problems =
          for section <- ReviewPacket.sections(packet),
              row <- section.rows,
              ReviewPacket.text(row, "kind") == "hunk",
              problem = hunk_row_problem(hunks_by_path, row),
              problem != nil,
              do: problem

        if problems == [],
          do: :ok,
          else: {:error, "Invalid packet: " <> Enum.join(Enum.take(problems, 10), "; ")}
    end
  end

  defp hunk_row_problem(hunks_by_path, row) do
    path = ReviewPacket.text(row, "path")
    hunk_index = ReviewPacket.int(row, "hunk_index")
    ref = "#{path}##{hunk_index}"

    case ReviewHunks.find(hunks_by_path, path, hunk_index) do
      nil ->
        "#{ref} is not a hunk in raw_diff"

      hunk ->
        rows = hunk_row_count(hunk)

        case {ReviewPacket.int(row, "line_start"), ReviewPacket.int(row, "line_end")} do
          {nil, nil} ->
            nil

          {first, last} when is_nil(first) or is_nil(last) ->
            "#{ref} needs both line_start and line_end, or neither"

          {first, last} when first >= 1 and first <= last and last <= rows ->
            nil

          {first, last} ->
            "#{ref}:L#{first}-L#{last} is outside the hunk, which has #{rows} rows"
        end
    end
  end

  # Rows after the @@ header, as the CLI counts them.
  defp hunk_row_count(hunk) do
    hunk.raw_diff
    |> String.split("\n")
    |> Enum.drop_while(&(not String.starts_with?(&1, "@@ ")))
    |> Enum.drop(1)
    |> Enum.count(&(&1 != "" and not String.starts_with?(&1, "\\")))
  end

  defp comment_params(_review, %{"thread_id" => thread_id} = args) when not is_nil(thread_id) do
    # A reply keeps its thread's file, side, anchor, and revision.
    # publish_comment validates these placeholders but does not store them.
    {:ok,
     %{
       "thread_id" => thread_id,
       "body" => args["body"],
       "file_path" => "(reply)",
       "side" => "new",
       "thread_anchor" => %{"granularity" => "line"}
     }}
  end

  defp comment_params(review, args) do
    side = args["side"] || "new"

    with {:path, path} when is_binary(path) <- {:path, args["path"]},
         {:line, line} when is_integer(line) <- {:line, args["line"]},
         {:ok, _revisions, selected} <- select_revision(review, args),
         {:ok, text} <- line_text(selected, path, side, line) do
      {:ok,
       %{
         "body" => args["body"],
         "file_path" => path,
         "side" => side,
         "originating_patchset_id" => selected.id,
         "thread_anchor" => %{
           "granularity" => "line",
           "line_number_hint" => line,
           "line_text" => text
         }
       }}
    else
      {:path, _} -> {:error, "Pass thread_id to reply, or path and line to start a thread."}
      {:line, _} -> {:error, "Pass thread_id to reply, or path and line to start a thread."}
      other -> other
    end
  end

  defp line_text(selected, path, side, line) do
    text =
      case ReviewsContext.get_file(selected, path) do
        nil -> nil
        file -> file |> Anchoring.index() |> Map.get({path, side}, %{}) |> Map.get(line)
      end

    if is_binary(text) do
      {:ok, text}
    else
      {:error,
       "Line #{line} on the #{side} side of #{path} is not in revision #{selected.number}'s diff. " <>
         "Comment on a changed or context line."}
    end
  end

  defp write_error({:error, %Result{} = result}), do: result
  defp write_error({:error, message}) when is_binary(message), do: error_result(message)

  defp write_error({:error, :patchset_not_found}),
    do: error_result("That revision does not exist.")

  defp write_error({:error, :forbidden}), do: error_result("Only the review's owner can do that.")
  defp write_error({:error, :empty_body}), do: error_result("body cannot be empty.")

  defp write_error({:error, :invalid_status}),
    do: error_result("status must be open or resolved.")

  defp write_error({:error, %Ecto.Changeset{} = changeset}), do: changeset_result(changeset)
  defp write_error({:error, _other}), do: error_result("The write failed. Nothing was saved.")

  defp changeset_result(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
      |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)

    error_result("Invalid input: #{errors}")
  end

  defp error_result(message), do: Result.new(message, is_error: true)
end
