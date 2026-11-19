defmodule ReviewsWeb.MCP.Handlers do
  @moduledoc """
  Tool, resource, and prompt handlers for `ReviewsWeb.MCP.Server`.

  Every handler resolves the caller from the request's verified principal,
  which `ReviewsWeb.MCP.Server.authenticate/2` derives from an existing Reviews
  API token, as a `Reviews.Principal`. Reviews are found by link, as on REST
  and the web page: anyone signed in can read any review whose slug or URL
  they have. Writes go through the context functions, so `Reviews.Policy`
  decides them the same way for every surface.

  Every read fits in `max_bytes`, counting metadata and both encodings of the
  result (see `ReviewsWeb.MCP.Budget`). Lists and long text continue with
  `next_cursor` or `next_offset`, which must be sent with the same `revision`.
  Reads load only the rows a page needs, not the whole review.
  """

  alias FastestMCP.Tools.Result
  alias Reviews.{Accounts, Paging, Principal, ReviewHunks, ReviewPacket, ReviewView}
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.Review
  alias Reviews.Threads
  alias ReviewsWeb.MCP.Budget

  @title_cap 500
  @line_text_cap 500
  @listed_comments 3
  @listed_comment_cap 1_000
  @page_fetch 200
  @feedback_limit 60_000
  @feedback_threads 50
  @feedback_comment_cap 2_000
  @feedback_comments 20
  @slug_pattern ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @bad_cursor "Invalid cursor. Pass next_cursor from the previous page unchanged."
  @too_small "max_bytes is too small for the next item. Call again with a larger max_bytes."

  ## Reads

  def whoami(_args, ctx) do
    %Principal{identity: identity, user: owner} = current_principal!(ctx)

    %{
      identity: identity_payload(identity),
      account: %{username: owner.username},
      scopes: ctx.verified_scopes || [],
      writes_enabled: ReviewsWeb.MCP.Server.writes_enabled?()
    }
  end

  def get_review(args, ctx) do
    with_review(args, ctx, fn review, _identity ->
      with :ok <- require_pinned_revision(args, args["cursor"]),
           {:ok, revisions, selected} <- select_revision(review, args),
           {:ok, cursor} <- decode_cursor(args, {:review, review.id, selected.number}) do
        cursor = review_position(cursor)
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

        left = room!(args, header)
        {body, next} = review_page(cursor, data, left, %{})

        if next && next == cursor do
          error_result(@too_small)
        else
          next = Paging.encode({:review, review.id, selected.number}, next)
          header |> Map.merge(body) |> Map.put(:next_cursor, next) |> with_hint(next)
        end
      end
    end)
  end

  def get_packet_section(args, ctx) do
    with_review(args, ctx, fn review, _identity ->
      scope = &{:section, review.id, &1.number, args["section_index"]}

      with :ok <- require_pinned_revision(args, args["cursor"]),
           {:ok, _revisions, selected} <- select_revision(review, args),
           {:ok, section, count} <- fetch_section(selected, args["section_index"]),
           {:ok, cursor} <- decode_cursor(args, scope.(selected)) do
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

        start = pair(cursor)
        left = room!(args, header)

        {rows, next} =
          stream_items(
            Enum.with_index(section.rows),
            start,
            left,
            fn {_row, index} -> index end,
            fn {row, index} -> section_row(row, index, hunks_by_path) end
          )

        if rows == [] and next != nil do
          error_result(@too_small)
        else
          next_cursor = encode_pair(scope.(selected), next)
          %{header | next_cursor: next_cursor} |> Map.put(:rows, rows) |> with_hint(next_cursor)
        end
      end
    end)
  end

  def list_files(args, ctx) do
    with_review(args, ctx, fn review, _identity ->
      with :ok <- require_pinned_revision(args, args["cursor"]),
           {:ok, _revisions, selected} <- select_revision(review, args),
           {:ok, cursor} <- decode_cursor(args, {:files, review.id, selected.number}) do
        {offset, _} = pair(cursor)
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
            room!(args, header),
            fn file ->
              %{
                file
                | path: file.path,
                  old_path: file.old_path
              }
              |> Map.put(:open_threads, Map.get(open, file.path, 0))
            end
          )

        cond do
          count == 0 and fetched != [] ->
            error_result(@too_small)

          count < length(fetched) ->
            next = encode_pair({:files, review.id, selected.number}, {offset + count, 0})
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
          path: args["path"],
          offset: offset,
          total_bytes: byte_size(raw),
          next_offset: byte_size(raw)
        }

        case Budget.fit_text(raw, offset, room!(args, header)) do
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
      status = args["status"] || "open"
      scope = &{:threads, review.id, &1.number, status, args["path"]}

      with {:ok, limit} <- page_limit(args["limit"]),
           :ok <- require_pinned_revision(args, args["cursor"]),
           {:ok, revisions, selected} <- select_revision(review, args),
           {:ok, cursor} <- decode_cursor(args, scope.(selected)) do
        {after_id, _} = pair(cursor)

        filters = [
          max_origin_number: selected.number,
          status: if(status != "all", do: status),
          path: args["path"]
        ]

        page = Threads.list_thread_page(review, filters, after_id, limit + 1)
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
          fill_threads(projected, comment_counts, room!(args, header))

        cond do
          count == 0 and page != [] ->
            error_result(@too_small)

          count < length(page) ->
            next = encode_pair(scope.(selected), {Enum.at(projected, count - 1).id, 0})
            %{header | next_cursor: next} |> Map.put(:threads, threads) |> with_hint(next)

          true ->
            Map.put(header, :threads, threads)
        end
      end
    end)
  end

  def get_thread(args, ctx) do
    with_review(args, ctx, fn review, _identity ->
      with :ok <- require_pinned_revision(args, args["cursor"]),
           {:ok, revisions, selected} <- select_revision(review, args),
           {:ok, thread} <- review_thread(review, args["thread_id"]),
           [projected] <- ReviewView.project_threads(review, revisions, selected, [thread]),
           {:ok, cursor} <-
             decode_cursor(args, {:thread, review.id, selected.number, thread.id}) do
        {start_id, _offset} = start = pair(cursor)
        comments = Threads.list_comment_page(thread.id, start_id - 1, @page_fetch)

        header =
          projected
          |> thread_summary(Threads.comment_counts([thread.id]) |> Map.get(thread.id, 0))
          |> Map.merge(%{slug: review.slug, revision: selected.number, next_cursor: nil})

        {page, next} =
          stream_items(
            comments,
            start,
            room!(args, header),
            & &1.id,
            &comment_parts/1
          )

        # A full page of comments may have more after it.
        next =
          if is_nil(next) and length(comments) == @page_fetch,
            do: {List.last(comments).id + 1, 0},
            else: next

        if page == [] and comments != [] do
          error_result(@too_small)
        else
          next_cursor = encode_pair({:thread, review.id, selected.number, thread.id}, next)

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
    %Principal{identity: identity} = current_principal!(ctx)

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

    with_review(args, ctx, fn review, principal ->
      with :ok <- validate_diff_and_packet(args["raw_diff"], args["packet"]),
           {:ok, %{patchset: ps}} <-
             ReviewsContext.append_patchset(review, principal, push_attrs(args)) do
        %{slug: review.slug, url: review_url(review), revision: ps.number}
      else
        other -> write_error(other)
      end
    end)
  end

  def post_comment(args, ctx) do
    ensure_writes_enabled!()

    with_review(args, ctx, fn review, principal ->
      with {:ok, params} <- comment_params(review, args),
           {:ok, %{thread: thread, comment: comment}} <-
             Threads.publish_comment(review, principal, params) do
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
          error_result(
            "No thread #{args["thread_id"]} on this review. List threads first.",
            :thread_not_found
          )

        other ->
          write_error(other)
      end
    end)
  end

  def update_thread_status(args, ctx) do
    ensure_writes_enabled!()

    with_review(args, ctx, fn review, principal ->
      case Threads.update_status(review, args["thread_id"], principal, args["status"]) do
        {:ok, thread} ->
          %{
            slug: review.slug,
            thread_id: thread.id,
            status: thread.status,
            resolved_by: identity_payload(thread.resolved_by)
          }

        {:error, :not_found} ->
          error_result(
            "No thread #{args["thread_id"]} on this review. List threads first.",
            :thread_not_found
          )

        other ->
          write_error(other)
      end
    end)
  end

  ## The review list

  @list_filters ~w(role status author q)

  @doc """
  The reviews the caller can find again, from `Reviews.ReviewIndex`: the
  same list and filters as `reviews list` and `GET /api/v1/reviews`.
  `Reviews.Policy.list_viewer/1` decides whose reviews: an OAuth connector or
  a human identity's token lists the whole account; an agent API token lists
  only its agent's. Pages continue with `next_cursor`, and each fits in
  `max_bytes`.
  """
  def list_reviews(args, ctx) do
    viewer = ctx |> current_principal!() |> Reviews.Policy.list_viewer()
    params = Map.take(args, @list_filters)
    scope = {:reviews_list, viewer_key(viewer), params}

    with {:ok, limit} <- page_limit(args["limit"]),
         {:ok, cursor} <- decode_cursor(args, scope),
         {offset, _} = pair(cursor),
         {:ok, filters} <- list_filters(params, limit, offset) do
      list_page(viewer, filters, scope, offset, args)
    end
    |> unwrap()
  catch
    :too_small -> error_result(@too_small)
    :bad_cursor -> error_result(@bad_cursor)
  end

  defp list_page(viewer, filters, scope, offset, args) do
    result = ReviewsContext.list_reviews(viewer, filters)

    header = %{
      scope: if(match?(%Reviews.Accounts.User{}, viewer), do: "account", else: "identity"),
      filters: Map.take(filters, [:role, :status, :author, :q]),
      next_cursor: nil
    }

    {reviews, _left, count} = Budget.fill(result.entries, room!(args, header), &list_entry/1)

    next =
      cond do
        count == 0 and result.entries != [] -> throw(:too_small)
        count < length(result.entries) -> offset + count
        true -> result.next_offset
      end

    next_cursor = next && Paging.encode(scope, {:position, next, 0})

    header
    |> Map.merge(%{reviews: reviews, next_cursor: next_cursor})
    |> with_list_hint(next_cursor)
  end

  defp viewer_key(%Reviews.Accounts.User{id: id}), do: {:user, id}
  defp viewer_key(%Reviews.Accounts.Identity{id: id}), do: {:identity, id}

  defp list_filters(params, limit, offset) do
    case Reviews.ReviewIndex.normalize_filters(
           Map.merge(params, %{"limit" => limit, "offset" => offset})
         ) do
      {:ok, filters} ->
        {:ok, filters}

      {:error, errors} ->
        {:error, Enum.map_join(errors, " ", fn {key, message} -> "#{key}: #{message}." end)}
    end
  end

  defp list_entry(entry) do
    review = entry.review

    %{
      slug: review.slug,
      title: Budget.cap(review.title, @title_cap),
      url: review_url(review),
      author: identity_payload(review.author),
      role: entry.role,
      revisions: entry.patchset_count,
      latest_revision: entry.latest_patchset_number,
      threads: entry.thread_count,
      open_threads: entry.open_thread_count,
      has_new_revision: entry.has_new_patchset,
      last_pushed_at: iso(entry.last_pushed_at),
      last_activity_at: iso(entry.last_activity_at),
      updated_at: iso(entry.updated_at)
    }
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at)

  defp with_list_hint(payload, nil), do: payload

  defp with_list_hint(payload, _next),
    do: Map.put(payload, :hint, "More follows. Call again with next_cursor and the same filters.")

  ## search and fetch, in the shape ChatGPT's connectors and deep research use

  @search_limit 20

  @doc """
  Reviews the caller's account owns that match `query`. Each result's `id` is
  the slug `fetch` takes. Search stays within the account: other reviews are
  readable by link, but a link isn't something to search for.
  """
  def search(args, ctx) do
    %Principal{identity: identity} = current_principal!(ctx)

    results =
      identity
      |> ReviewsContext.search_owned_reviews(args["query"] || "", @search_limit)
      |> Enum.map(fn review ->
        %{id: review.slug, title: Budget.cap(review.title, @title_cap), url: review_url(review)}
      end)

    %{results: results}
  end

  @doc """
  One review as a document: its description, then its open feedback as
  Markdown, the same text as the `reviews://{slug}/feedback` resource. The
  whole result fits in the largest `max_bytes`; a longer document is cut
  short with a note naming the tools that read the rest, and
  `metadata.complete` is false.
  """
  def fetch(%{"id" => id}, _ctx) do
    with {:ok, review} <- find_review(id),
         {:ok, revisions, latest} <- select_revision(review, %{}) do
      title = Budget.cap(review.title, @title_cap)

      description =
        if review.description in [nil, ""], do: "", else: review.description <> "\n\n"

      {feedback, feedback_complete?} = feedback_with_status(review, revisions, latest)
      text = "# #{title}\n\n" <> description <> feedback

      doc = %{
        id: review.slug,
        title: title,
        text: "",
        url: review_url(review),
        metadata: %{
          revision: latest.number,
          open_threads:
            Threads.count_threads(review, max_origin_number: latest.number, status: "open"),
          complete: false
        }
      }

      left = Budget.available(Paging.max_bytes_limit(), doc)

      case Budget.fit_text(text, 0, left) do
        # Left-out threads and comments are named in the feedback text itself.
        {all, nil} ->
          %{doc | text: all} |> put_in([:metadata, :complete], feedback_complete?)

        _too_long ->
          note =
            "\n\n_Cut short to fit. Read the rest with reviews_get_review and " <>
              "reviews_list_threads (review #{review.slug})._"

          {chunk, _next} = Budget.fit_text(text, 0, left - Budget.cost(note))
          %{doc | text: chunk <> note}
      end
    else
      _ -> error_result(not_found_message(id))
    end
  end

  ## Resources and prompts

  def feedback_markdown(%{"slug" => slug}, ctx) do
    _ = current_principal!(ctx)

    with {:ok, review} <- find_review(slug),
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

  # API tokens carry every scope. An OAuth token (it names a grant) carries
  # only its granted scopes, so `Reviews.Policy` limits its writes to them, and
  # its comments record which app posted them.
  defp current_principal!(%{principal: %{"identity_id" => id} = principal})
       when is_integer(id) do
    identity = Accounts.get_identity!(id)
    user = Accounts.get_user!(identity.owner_user_id)

    case principal do
      %{"grant_id" => _, "scopes" => scopes} ->
        Principal.delegated(identity, user, scopes, attribution(principal, identity, user), :mcp)

      _ ->
        Principal.new(identity, :mcp, user)
    end
  end

  # Stored with each comment. `link_id` is the grant's ID, the name comments
  # already use for it.
  defp attribution(%{"grant_id" => grant_id, "client_id" => client_id}, identity, user) do
    %{
      "provider" => "mcp",
      "verified_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "client_id" => client_id,
      "link_id" => grant_id,
      "owner_user_id" => user.id,
      "owner_username" => user.username,
      "identity_id" => identity.id,
      "identity_handle" => identity.handle
    }
  end

  defp with_review(args, ctx, fun) do
    principal = current_principal!(ctx)

    case find_review(args["review"]) do
      {:ok, review} ->
        try do
          fun.(review, principal) |> unwrap()
        catch
          :too_small -> error_result(@too_small)
          :bad_cursor -> error_result(@bad_cursor)
        end

      {:error, :not_found} ->
        error_result(not_found_message(args["review"]), :review_not_found)
    end
  end

  defp unwrap({:error, %Result{} = result}), do: result
  defp unwrap(%Result{} = result), do: result

  defp unwrap({:error, :patchset_not_found}),
    do: error_result("That revision does not exist.", :patchset_not_found)

  defp unwrap({:error, message}) when is_binary(message), do: error_result(message)
  defp unwrap(value), do: value

  defp find_review(ref) do
    with {:ok, slug} <- parse_review_ref(ref),
         %Review{} = review <- ReviewsContext.get_review_by_slug(slug),
         true <- Reviews.Policy.can?(nil, :read, review) do
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
    "No review matching #{inspect(ref)}. Check the slug or URL."
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
         error_result(
           "Revision #{selected.number} has no packet. Use reviews_list_files and reviews_get_file_diff.",
           :section_not_found
         )}

      section = Enum.find(sections, &(&1.index == index)) ->
        {:ok, section, length(sections)}

      true ->
        {:error,
         error_result(
           "No packet section #{index}. Section indexes start at 0.",
           :section_not_found
         )}
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
      {:ok, thread} ->
        {:ok, thread}

      {:error, :not_found} ->
        {:error, error_result("No thread #{thread_id} on this review.", :thread_not_found)}
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

  # The tool schemas already bound max_bytes and limit; Paging owns the bounds.
  defp max_bytes(args) do
    case Paging.max_bytes(args["max_bytes"]) do
      {:ok, max_bytes} -> max_bytes
      {:error, _} -> throw(:too_small)
    end
  end

  defp page_limit(limit) do
    case Paging.limit(limit) do
      {:ok, limit} -> {:ok, limit}
      {:error, _} -> {:error, "limit must be between 1 and #{Paging.max_limit()}."}
    end
  end

  # Bytes left after the page header, or a "too small" error when the header
  # alone does not fit, such as a thread with a long path and anchor.
  defp room!(args, header) do
    left = Budget.available(max_bytes(args), header)
    if left < 0, do: throw(:too_small), else: left
  end

  ## Cursors

  # Cursor grammar and query binding live in `Reviews.Paging`.

  defp decode_cursor(args, scope) do
    case Paging.decode(args["cursor"], scope) do
      {:ok, position} -> {:ok, position}
      {:error, :invalid_cursor} -> {:error, @bad_cursor}
    end
  end

  # A plain list position as `{a, b}`, starting at `{0, 0}`.
  defp pair(nil), do: {0, 0}
  defp pair({:position, a, b}), do: {a, b}
  defp pair(_other), do: throw(:bad_cursor)

  defp encode_pair(_scope, nil), do: nil
  defp encode_pair(scope, {a, b}), do: Paging.encode(scope, {:position, a, b})

  # get_review pages through phases; a plain position is not one of them.
  defp review_position(nil), do: {:fields, 0, 0}
  defp review_position({:position, _a, _b}), do: throw(:bad_cursor)
  defp review_position(position), do: position

  defp with_hint(payload, nil), do: payload

  defp with_hint(payload, _next),
    do: Map.put(payload, :hint, "More follows. Call again with next_cursor and this revision.")

  ## Paging

  # get_review pages through its long text fields, then the packet outline,
  # then the revisions, newest first.
  defp review_page({:fields, index, offset}, data, left, acc) do
    case stream_fields(data.fields, index, offset, left) do
      {out, left, nil} -> review_page({:sections, 0, 0}, data, left, Map.merge(acc, out))
      {out, _left, next} -> {Map.merge(acc, out), next}
    end
  end

  defp review_page({:sections, index, _}, data, left, acc) do
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
      do: {acc, {:sections, index + count, 0}},
      else: review_page({:revisions, 0, 0}, data, left, acc)
  end

  defp review_page({:revisions, index, _}, data, left, acc) do
    rest = Enum.drop(data.revisions, index)

    {revisions, _left, count} =
      Budget.fill(rest, left, fn revision ->
        revision
        |> Map.take([:number, :pushed_at, :base_sha, :packet_present, :stats])
        |> Map.put(:branch_name, Budget.cap(revision.branch_name, 255))
      end)

    acc = Map.put(acc, :revisions, revisions)
    {acc, if(count < length(rest), do: {:revisions, index + count, 0})}
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
  defp stream_items(items, {start_key, start_offset}, left, key, render) do
    # Lazy, so items before the cursor and after a full page are never rendered.
    items
    |> Stream.drop_while(&(key.(&1) < start_key))
    |> Stream.map(&{key.(&1), render.(&1)})
    |> Enum.reduce_while({[], left}, fn {key, {meta, text_key, text}}, {acc, left} ->
      from = if key == start_key, do: start_offset, else: 0

      case fit_entry(meta, text_key, text, from, left, 0) do
        nil -> {:halt, {Enum.reverse(acc), {key, from}}}
        {entry, nil, cost} -> {:cont, {[entry | acc], left - cost}}
        {entry, next, _cost} -> {:halt, {Enum.reverse([entry | acc]), {key, next}}}
      end
    end)
    |> case do
      {entries, {_key, _offset} = next} -> {entries, next}
      {entries, _left} -> {Enum.reverse(entries), nil}
    end
  end

  # The largest entry for this item, metadata and text included, whose
  # complete cost fits `left`; nil when not even its metadata and one
  # character fit. `slack` shrinks the text after an estimate came out high.
  defp fit_entry(meta, text_key, text, from, left, slack) do
    base_cost = Budget.cost(entry(meta, text_key, "", from, false)) + 4
    text_budget = left - base_cost - slack

    # Text already returned in full (or empty) is complete; its empty field is
    # in base_cost, so it needs no text budget.
    {chunk, next} =
      cond do
        from >= byte_size(text) -> {"", nil}
        text_budget >= 0 -> Budget.fit_text(text, from, text_budget)
        true -> {"", from}
      end

    cond do
      text_budget < 0 or (chunk == "" and from < byte_size(text)) ->
        nil

      true ->
        entry = entry(meta, text_key, chunk, from, is_nil(next))
        cost = Budget.cost(entry) + 4

        if cost <= left,
          do: {entry, next, cost},
          else: fit_entry(meta, text_key, text, from, left, slack + cost - left)
    end
  end

  defp entry(meta, text_key, chunk, from, complete?),
    do: Map.merge(meta, %{text_key => chunk, :offset => from, :complete => complete?})

  ## Payloads

  defp section_row(row, index, hunks_by_path) do
    case ReviewPacket.text(row, "kind") do
      "hunk" ->
        hunk = ReviewHunks.for_packet_row(hunks_by_path, row)

        meta = %{
          row: index,
          kind: "hunk",
          path: ReviewPacket.text(row, "path"),
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
    meta = comment |> ReviewsWeb.Payloads.comment(:compact) |> Map.delete(:body)

    {meta, :body, comment.body || ""}
  end

  defp thread_summary(thread, comment_count) do
    thread
    |> ReviewsWeb.Payloads.thread()
    |> Map.take([:id, :path, :side, :line, :anchor_status, :originating_revision, :status])
    |> Map.merge(%{
      line_text: Budget.cap(thread.original_anchor["line_text"], @line_text_cap),
      resolved_by: identity_payload(thread.resolved_by),
      comment_count: comment_count
    })
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
        comment
        |> ReviewsWeb.Payloads.comment(:compact)
        |> Map.merge(%{
          body: Budget.cap(comment.body, @listed_comment_cap),
          body_truncated: byte_size(comment.body || "") > @listed_comment_cap
        })
      end)

    complete =
      comment_count <= length(comments) and not Enum.any?(comments, & &1.body_truncated)

    thread
    |> thread_summary(comment_count)
    |> Map.merge(%{comments: comments, comments_complete: complete})
  end

  defp identity_payload(identity), do: ReviewsWeb.Payloads.identity(identity, :compact)

  defp review_url(review), do: ReviewsWeb.Endpoint.url() <> "/r/" <> review.slug

  # Bounded like the tools: at most @feedback_threads threads and
  # @feedback_limit bytes, with a note naming what was left out.
  defp render_feedback(review, revisions, latest),
    do: review |> feedback_with_status(revisions, latest) |> elem(0)

  # The feedback text, and whether it shows every open thread and comment.
  defp feedback_with_status(review, revisions, latest) do
    filters = [max_origin_number: latest.number, status: "open"]
    total = Threads.count_threads(review, filters)
    page = Threads.list_thread_page(review, filters, 0, @feedback_threads)
    threads = ReviewView.project_threads(review, revisions, latest, page)

    header = """
    # Open feedback: #{Budget.cap(review.title, @title_cap)}

    Review: #{review_url(review)} (revision #{latest.number})
    Open threads: #{total}
    """

    {sections, shown, all_comments?, _left} =
      Enum.reduce_while(
        threads,
        {[], 0, true, @feedback_limit - byte_size(header)},
        fn thread, {acc, shown, all?, left} ->
          {text, complete?} = render_feedback_thread(thread)

          if byte_size(text) <= left,
            do: {:cont, {[text | acc], shown + 1, all? and complete?, left - byte_size(text)}},
            else: {:halt, {acc, shown, all?, left}}
        end
      )

    omitted =
      if shown < total,
        do: [
          "_#{total - shown} more open threads are not shown. Read them with reviews_list_threads._\n"
        ],
        else: []

    {Enum.join([header | Enum.reverse(sections)] ++ omitted, "\n"),
     shown == total and all_comments?}
  end

  defp render_feedback_thread(thread) do
    location =
      case thread.anchor do
        %{"line_number_hint" => line} ->
          "#{thread.file_path}:#{line}"

        _ ->
          "#{thread.file_path} (outdated, from revision #{thread.originating_patchset_number})"
      end

    page = Threads.list_comment_page(thread.id, 0, @feedback_comments + 1)
    shown = Enum.take(page, @feedback_comments)

    comments =
      Enum.map_join(shown, "\n", fn comment ->
        author = comment.author && comment.author.handle
        body = comment.body || ""
        cut = byte_size(body) > @feedback_comment_cap

        "- **#{author}**: #{Budget.cap(body, @feedback_comment_cap)}#{if cut, do: " _(cut short)_"}"
      end)

    incomplete? =
      length(page) > @feedback_comments or
        Enum.any?(shown, &(byte_size(&1.body || "") > @feedback_comment_cap))

    note =
      if incomplete?,
        do:
          "\n_Some comments on this thread are cut short or not shown. Read them all with " <>
            "reviews_get_thread (thread_id #{thread.id})._\n",
        else: ""

    {"## Thread #{thread.id} at `#{location}` (#{thread.side})\n\n#{comments}\n#{note}",
     not incomplete?}
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

  # Keep the MCP empty-diff guard; packet rules belong to the domain layer.
  defp validate_diff_and_packet(raw_diff, _packet) do
    case ReviewsContext.parse_diff_files(raw_diff) do
      [] -> {:error, "raw_diff has no files. Send the output of `git diff`."}
      _ -> :ok
    end
  end

  defp comment_params(_review, %{"thread_id" => thread_id} = args) when not is_nil(thread_id) do
    {:ok, %{"thread_id" => thread_id, "body" => args["body"]}}
  end

  defp comment_params(review, args) do
    side = args["side"] || "new"

    with {:path, path} when is_binary(path) <- {:path, args["path"]},
         {:line, line} when is_integer(line) <- {:line, args["line"]},
         {:ok, _revisions, selected} <- select_revision(review, args) do
      {:ok,
       %{
         "body" => args["body"],
         "file_path" => path,
         "side" => side,
         "originating_patchset_id" => selected.id,
         "thread_anchor" => %{
           "granularity" => "line",
           "line_number_hint" => line
         }
       }}
    else
      {:path, _} -> {:error, "Pass thread_id to reply, or path and line to start a thread."}
      {:line, _} -> {:error, "Pass thread_id to reply, or path and line to start a thread."}
      other -> other
    end
  end

  defp write_error({:error, %Result{} = result}), do: result
  defp write_error({:error, message}) when is_binary(message), do: error_result(message)

  defp write_error({:error, :patchset_not_found}),
    do: error_result("That revision does not exist.", :patchset_not_found)

  defp write_error({:error, :invalid_anchor}),
    do:
      error_result(
        "The anchor is not in the selected revision's diff. Comment on a changed or context line.",
        :invalid_anchor
      )

  defp write_error({:error, :forbidden}),
    do:
      error_result(
        "You cannot do that on this review. Only its owner can push revisions, and only " <>
          "its owner or a thread's author can resolve or reopen that thread.",
        :forbidden
      )

  defp write_error({:error, :invalid_file_path}),
    do: error_result("file_path is required", :invalid_file_path)

  defp write_error({:error, :empty_body}), do: error_result("body cannot be empty.", :empty_body)

  defp write_error({:error, :invalid_status}),
    do: error_result("status must be open or resolved.", :invalid_status)

  defp write_error({:error, %Ecto.Changeset{} = changeset}), do: changeset_result(changeset)

  defp write_error({:error, _other}),
    do: error_result("The write failed. Nothing was saved.", :write_failed)

  defp changeset_result(changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Keyword.get(opts, :detail, message)
      end)
      |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)

    error_result("Invalid input: #{errors}", changeset)
  end

  # Codes come from the shared vocabulary (`Reviews.Errors`), as on REST.
  defp error_result(message, reason \\ :invalid_request),
    do:
      Result.new(message,
        is_error: true,
        structured_content: %{
          error: %{code: to_string(Reviews.Errors.code(reason)), detail: message}
        }
      )
end
