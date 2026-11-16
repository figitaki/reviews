defmodule ReviewsWeb.MCP.Handlers do
  @moduledoc """
  Tool, resource, and prompt handlers for `ReviewsWeb.MCP.Server`.

  Every handler resolves the caller from the request's verified principal,
  which `ReviewsWeb.MCP.Server.authenticate/2` derives from an existing Reviews
  API token. Reviews are scoped to the caller's account: the author's human
  identity and its sibling agent identities. Unknown and foreign reviews get
  the same not-found result.

  Responses are bounded: diffs and prose are split at UTF-8 boundaries and
  continue with an explicit offset or cursor pinned to a revision.
  """

  alias FastestMCP.Tools.Result
  alias Reviews.{Accounts, Anchoring, ReviewHunks, ReviewNavigation, ReviewPacket, ReviewView}
  alias Reviews.Accounts.Identity
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.{Patchset, Review}
  alias Reviews.Threads

  @default_max_bytes 40_000
  @max_bytes_limit 120_000
  @comment_body_limit 4_000
  @default_thread_limit 25
  @thread_limit 100
  @slug_pattern ~r/\A[A-Za-z0-9_-]{1,64}\z/

  def default_max_bytes, do: @default_max_bytes
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
    with_review(args, ctx, fn review, identity ->
      with {:ok, snapshot} <- snapshot(review, identity, args) do
        ps = snapshot.selected_patchset
        threads = snapshot.published_threads

        %{
          slug: review.slug,
          title: review.title,
          description: review.description,
          url: review_url(review),
          revision: ps && ps.number,
          revisions: Enum.map(snapshot.patchsets, &revision_payload/1),
          packet: ps && packet_outline(ps.packet),
          threads: %{
            open: Enum.count(threads, &(&1.status == "open")),
            resolved: Enum.count(threads, &(&1.status == "resolved")),
            outdated: Enum.count(threads, &(&1.anchor_status == "outdated"))
          }
        }
      end
    end)
  end

  def get_packet_section(args, ctx) do
    with_review(args, ctx, fn review, identity ->
      with {:ok, %{selected_patchset: %Patchset{} = ps} = snapshot} <-
             snapshot(review, identity, args),
           {:ok, section} <- fetch_section(ps, args["section_index"]) do
        budget = max_bytes(args)

        {rows, truncated?} =
          Enum.map_reduce(section.rows, {budget, false}, fn row, acc ->
            section_row(row, snapshot.hunks_by_path, acc)
          end)
          |> then(fn {rows, {_left, truncated?}} -> {rows, truncated?} end)

        %{
          slug: review.slug,
          revision: ps.number,
          section_index: section.index,
          section_count: length(ReviewPacket.sections(ps.packet)),
          title: section.title,
          rows: rows,
          truncated: truncated?,
          hint:
            if(truncated?,
              do:
                "Some rows were cut to fit max_bytes. Read omitted hunks with reviews_get_file_diff."
            )
        }
      else
        {:ok, _snapshot} -> error_result("This review has no revisions.")
        other -> other
      end
    end)
  end

  def list_files(args, ctx) do
    with_review(args, ctx, fn review, _identity ->
      with {:ok, ps} <- pick_patchset(review, args) do
        open_counts =
          review.id
          |> Threads.list_published_threads()
          |> Enum.filter(&(&1.status == "open"))
          |> Enum.frequencies_by(& &1.file_path)

        files =
          ps
          |> ReviewsContext.list_files()
          |> Enum.map(fn file ->
            %{
              path: file.path,
              old_path: file.old_path,
              status: file.status,
              additions: file.additions,
              deletions: file.deletions,
              bytes: byte_size(file.raw_diff || ""),
              open_threads: Map.get(open_counts, file.path, 0)
            }
          end)

        %{slug: review.slug, revision: ps.number, files: files}
      end
    end)
  end

  def get_file_diff(args, ctx) do
    with_review(args, ctx, fn review, _identity ->
      offset = args["offset"] || 0

      with :ok <- require_pinned_revision(args, offset),
           {:ok, ps} <- pick_patchset(review, args),
           {:ok, raw} <- file_diff(ps, args["path"]),
           {:ok, chunk, next_offset} <- take_bytes(raw, offset, max_bytes(args)) do
        %{
          slug: review.slug,
          revision: ps.number,
          path: args["path"],
          offset: offset,
          total_bytes: byte_size(raw),
          diff: chunk,
          next_offset: next_offset
        }
      end
    end)
  end

  def list_threads(args, ctx) do
    with_review(args, ctx, fn review, identity ->
      cursor = parse_cursor(args["cursor"])
      limit = args["limit"] || @default_thread_limit

      with :ok <- require_pinned_revision(args, cursor || 0),
           {:ok, snapshot} <- snapshot(review, identity, args) do
        status = args["status"] || "open"

        threads =
          snapshot.published_threads
          |> Enum.filter(&(status == "all" or &1.status == status))
          |> Enum.filter(&(is_nil(args["path"]) or &1.file_path == args["path"]))

        page = threads |> Enum.drop(cursor || 0) |> Enum.take(limit)
        next = (cursor || 0) + length(page)

        %{
          slug: review.slug,
          revision: snapshot.selected_patchset && snapshot.selected_patchset.number,
          status: status,
          total: length(threads),
          threads: Enum.map(page, &thread_payload/1),
          next_cursor: if(next < length(threads), do: Integer.to_string(next))
        }
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
         {:ok, snapshot} <- ReviewView.snapshot(review, identity) do
      FastestMCP.Resources.Text.new(render_feedback(review, snapshot),
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
       points at (reviews_get_file_diff or reviews_get_packet_section).
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

  defp snapshot(review, identity, args) do
    ReviewView.snapshot(review, identity, patchset_number: args["revision"])
  end

  defp pick_patchset(review, args) do
    case ReviewView.pick_patchset(ReviewsContext.list_patchsets(review), args["revision"]) do
      %Patchset{} = ps -> {:ok, ps}
      nil -> {:error, :patchset_not_found}
    end
  end

  # A continuation must name the revision it continues, so a new push never
  # splices pages from two revisions together.
  defp require_pinned_revision(%{"revision" => n}, _offset) when is_integer(n), do: :ok
  defp require_pinned_revision(_args, 0), do: :ok

  defp require_pinned_revision(_args, _offset),
    do: {:error, "Pass the revision returned with the previous page to continue."}

  defp fetch_section(ps, index) do
    cond do
      not ReviewPacket.present?(ps.packet) ->
        {:error,
         "Revision #{ps.number} has no packet. Use reviews_list_files and reviews_get_file_diff."}

      section = ReviewPacket.section_at(ps.packet, index) ->
        {:ok, section}

      true ->
        {:error, "No packet section #{index}. Section indexes start at 0."}
    end
  end

  defp file_diff(ps, path) do
    case Enum.find(ReviewsContext.list_files(ps), &(&1.path == path)) do
      nil ->
        {:error, "No file #{inspect(path)} in this revision. Call reviews_list_files."}

      file ->
        {:ok, file.raw_diff || ReviewsContext.raw_diff_for_file(ps, path) || ""}
    end
  end

  defp max_bytes(args), do: args["max_bytes"] || @default_max_bytes

  defp parse_cursor(nil), do: nil

  defp parse_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  ## Bounded text

  @doc false
  # Returns the bytes of `binary` from `offset`, at most `max` of them, ending
  # on a line break when one falls in the second half of the window and never
  # inside a UTF-8 sequence.
  def take_bytes(binary, offset, max) when offset >= 0 and offset <= byte_size(binary) do
    if offset > 0 and offset < byte_size(binary) and continuation?(binary, offset) do
      {:error, "offset #{offset} is not a valid position. Use next_offset from the last page."}
    else
      rest = binary_part(binary, offset, byte_size(binary) - offset)

      if byte_size(rest) <= max do
        {:ok, rest, nil}
      else
        cut =
          case utf8_cut(rest, max) do
            # A window smaller than one character still makes progress.
            0 -> byte_size(String.first(rest))
            cut -> line_cut(rest, cut)
          end

        next = if cut < byte_size(rest), do: offset + cut
        {:ok, binary_part(rest, 0, cut), next}
      end
    end
  end

  def take_bytes(_binary, offset, _max),
    do: {:error, "offset #{offset} is past the end of the diff."}

  defp continuation?(binary, at), do: match?(<<0b10::2, _::6>>, binary_part(binary, at, 1))

  defp utf8_cut(binary, cut) when cut > 0 do
    if continuation?(binary, cut), do: utf8_cut(binary, cut - 1), else: cut
  end

  defp utf8_cut(_binary, 0), do: 0

  defp line_cut(binary, cut) do
    case :binary.matches(binary, "\n", scope: {0, cut}) do
      [] ->
        cut

      matches ->
        {pos, 1} = List.last(matches)
        if pos + 1 >= div(cut, 2), do: pos + 1, else: cut
    end
  end

  defp truncate(text, max) when is_binary(text) do
    case take_bytes(text, 0, max) do
      {:ok, chunk, nil} -> {chunk, false}
      {:ok, chunk, _next} -> {chunk, true}
    end
  end

  defp truncate(_text, _max), do: {"", false}

  ## Payloads

  defp revision_payload(ps) do
    %{
      number: ps.number,
      pushed_at: ps.pushed_at,
      branch_name: ps.branch_name,
      base_sha: ps.base_sha,
      packet_present: ReviewPacket.present?(ps.packet),
      stats: ReviewNavigation.patchset_stats(ps)
    }
  end

  defp packet_outline(packet) do
    if ReviewPacket.present?(packet) do
      %{
        title: ReviewPacket.text(packet, "title"),
        summary: ReviewPacket.text(packet, "summary") |> truncate(2_000) |> elem(0),
        sections:
          Enum.map(ReviewPacket.sections(packet), fn section ->
            %{index: section.index, title: section.title, hunks: length(section.refs)}
          end)
      }
    end
  end

  defp section_row(row, hunks_by_path, {left, truncated?}) do
    case ReviewPacket.text(row, "kind") do
      "hunk" ->
        hunk = ReviewHunks.for_packet_row(hunks_by_path, row)
        diff = hunk && hunk.display_raw_diff
        fits? = is_binary(diff) and byte_size(diff) <= left

        payload = %{
          kind: "hunk",
          path: ReviewPacket.text(row, "path"),
          hunk_index: ReviewPacket.int(row, "hunk_index"),
          line_start: hunk && hunk.line_start,
          line_end: hunk && hunk.line_end,
          diff: if(fits?, do: diff),
          missing: is_nil(hunk)
        }

        left = if fits?, do: left - byte_size(diff), else: left
        {payload, {left, truncated? or (not is_nil(hunk) and not fits?)}}

      kind ->
        {body, cut?} = truncate(ReviewPacket.text(row, "body"), max(left, 0))
        {%{kind: kind, body: body}, {left - byte_size(body), truncated? or cut?}}
    end
  end

  defp thread_payload(thread) do
    %{
      id: thread.id,
      path: thread.file_path,
      side: thread.side,
      line: thread.anchor && thread.anchor["line_number_hint"],
      line_text: thread.original_anchor && thread.original_anchor["line_text"],
      anchor_status: thread.anchor_status,
      originating_revision: thread.originating_patchset_number,
      status: thread.status,
      resolved_by: identity_payload(thread.resolved_by),
      comments:
        Enum.map(thread.comments, fn comment ->
          {body, cut?} = truncate(comment.body, @comment_body_limit)

          %{
            id: comment.id,
            author: identity_payload(comment.author),
            body: body,
            body_truncated: cut?,
            inserted_at: comment.inserted_at
          }
        end)
    }
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

  defp render_feedback(review, snapshot) do
    open = Enum.filter(snapshot.published_threads, &(&1.status == "open"))
    revision = snapshot.selected_patchset && snapshot.selected_patchset.number

    header = """
    # Open feedback: #{review.title}

    Review: #{review_url(review)} (revision #{revision})
    Open threads: #{length(open)}
    """

    threads =
      Enum.map(open, fn thread ->
        location =
          case thread.anchor do
            %{"line_number_hint" => line} ->
              "#{thread.file_path}:#{line}"

            _ ->
              "#{thread.file_path} (outdated, from revision #{thread.originating_patchset_number})"
          end

        comments =
          Enum.map_join(thread.comments, "\n", fn comment ->
            {body, cut?} = truncate(comment.body, @comment_body_limit)
            author = comment.author && comment.author.handle
            "- **#{author}**: #{body}#{if cut?, do: " …"}"
          end)

        "## Thread #{thread.id} at `#{location}` (#{thread.side})\n\n#{comments}\n"
      end)

    Enum.join([header | threads], "\n")
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
  # so check that every hunk row points at a hunk in the supplied diff.
  defp validate_diff_and_packet(raw_diff, packet) do
    files = ReviewsContext.parse_diff_files(raw_diff)

    cond do
      files == [] ->
        {:error, "raw_diff has no files. Send the output of `git diff`."}

      is_nil(packet) ->
        :ok

      true ->
        hunks_by_path = ReviewHunks.for_files(files)

        missing =
          for section <- ReviewPacket.sections(packet),
              row <- section.rows,
              ReviewPacket.text(row, "kind") == "hunk",
              is_nil(ReviewHunks.for_packet_row(hunks_by_path, row)),
              do: ReviewPacket.row_ref(row)

        if missing == [],
          do: :ok,
          else:
            {:error, "Packet rows point at hunks not in raw_diff: #{Enum.join(missing, ", ")}"}
    end
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
         {:ok, ps} <- pick_patchset(review, args),
         {:ok, text} <- line_text(ps, path, side, line) do
      {:ok,
       %{
         "body" => args["body"],
         "file_path" => path,
         "side" => side,
         "originating_patchset_id" => ps.id,
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

  defp line_text(ps, path, side, line) do
    case ps |> Anchoring.index() |> Map.get({path, side}, %{}) |> Map.get(line) do
      nil ->
        {:error,
         "Line #{line} on the #{side} side of #{path} is not in revision #{ps.number}'s diff. " <>
           "Comment on a changed or context line."}

      text ->
        {:ok, text}
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
