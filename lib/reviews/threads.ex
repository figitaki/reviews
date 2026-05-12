defmodule Reviews.Threads do
  @moduledoc """
  The Threads context: discussion threads, draft/published comments, and
  per-reviewer review summaries.

  Drafts are per-author and private until published. Publishing flips every
  draft comment + the (optional) review summary from `state: "draft"` to
  `"published"` in a single transaction and broadcasts each thread on the
  `"review:<slug>"` PubSub channel so other open LiveViews update without
  a refresh.
  """
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Reviews.Repo
  alias Reviews.Reviews.Review
  alias Reviews.Accounts.User
  alias Reviews.Threads.{Comment, ReviewSummary, Thread}

  @pubsub Reviews.PubSub

  ## Queries

  @doc """
  All published threads for a review, with their published comments preloaded
  and ordered. Drafts are intentionally excluded — callers fetch viewer drafts
  via `list_drafts_for/2`.
  """
  def list_published_threads(review_id) when is_integer(review_id) do
    published_comments_query =
      from c in Comment,
        where: c.state == "published",
        order_by: [asc: c.inserted_at]

    query =
      from t in Thread,
        where: t.review_id == ^review_id,
        order_by: [asc: t.inserted_at],
        preload: [comments: ^published_comments_query, author: []]

    # Drop threads that ended up with zero published comments (e.g. a thread
    # whose only comment was deleted before publish).
    Repo.all(query)
    |> Enum.filter(fn t -> t.comments != [] end)
  end

  @doc """
  All draft Threads + their draft Comment authored by `author` on `review`.
  Returned as `[%{thread: thread, comment: comment}]` for easy rendering in
  the publish modal.
  """
  def list_drafts_for(%Review{id: review_id}, %User{id: author_id}) do
    query =
      from c in Comment,
        join: t in assoc(c, :thread),
        where: c.state == "draft",
        where: c.author_id == ^author_id,
        where: t.review_id == ^review_id,
        order_by: [asc: t.file_path, asc: t.inserted_at],
        select: {c, t}

    Repo.all(query)
    |> Enum.map(fn {comment, thread} -> %{thread: thread, comment: comment} end)
  end

  @doc """
  Returns the optional draft ReviewSummary for this round (latest patchset)
  authored by `author` on `review`, or `nil`.
  """
  def get_draft_summary(%Review{id: review_id}, %User{id: author_id}, round_number) do
    Repo.one(
      from s in ReviewSummary,
        where:
          s.review_id == ^review_id and s.author_id == ^author_id and
            s.round_number == ^round_number and s.state == "draft",
        limit: 1
    )
  end

  ## Drafting

  @doc """
  Upserts a draft Comment for `author` on `review`. Creates the Thread on
  first save (keyed by file_path + side + the JSON-roundtripped anchor) and
  re-uses an existing draft Comment if one already exists for this
  `(thread, author)` pair. Returns `{:ok, %{thread: t, comment: c}}` or
  `{:error, reason}`.

  `params` is the JSON-decoded payload from the `save_draft` LiveView event:

      %{
        "file_path"     => "lib/foo.ex",
        "side"          => "old" | "new",
        "body"          => "...",
        "thread_anchor" => %{"granularity" => "line", ...}
      }

  Optional: `"thread_id"` to update an existing thread (used when a reviewer
  edits their draft on an already-saved thread).
  """
  def save_draft(%Review{} = review, %User{} = author, params) when is_map(params) do
    file_path = params["file_path"] || params[:file_path]
    side = params["side"] || params[:side]
    body = String.trim(to_string(params["body"] || params[:body] || ""))
    anchor = params["thread_anchor"] || params[:thread_anchor] || %{}
    thread_id = params["thread_id"] || params[:thread_id]

    cond do
      body == "" ->
        {:error, :empty_body}

      side not in ["old", "new"] ->
        {:error, :invalid_side}

      !is_binary(file_path) or file_path == "" ->
        {:error, :invalid_file_path}

      !is_map(anchor) or not Map.has_key?(anchor, "granularity") ->
        {:error, :invalid_anchor}

      true ->
        Repo.transaction(fn ->
          thread = fetch_or_create_thread(review, author, thread_id, file_path, side, anchor)
          comment = upsert_draft_comment(thread, author, body)
          %{thread: thread, comment: comment}
        end)
        |> case do
          {:ok, %{} = result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    error in [Ecto.InvalidChangesetError, Postgrex.Error] -> {:error, error}
  end

  defp fetch_or_create_thread(review, author, thread_id, file_path, side, anchor)
       when is_integer(thread_id) do
    case Repo.get(Thread, thread_id) do
      %Thread{review_id: rid} = thread when rid == review.id -> thread
      _ -> create_thread(review, author, file_path, side, anchor)
    end
  end

  defp fetch_or_create_thread(review, author, _thread_id, file_path, side, anchor) do
    create_thread(review, author, file_path, side, anchor)
  end

  defp create_thread(review, author, file_path, side, anchor) do
    # `originating_patchset_id` is the latest patchset for this review at the
    # moment of saving — the thread "originates" from what the author was
    # looking at. We grab it lazily so tests that seed a single patchset work.
    originating_patchset_id =
      Repo.one(
        from p in Reviews.Reviews.Patchset,
          where: p.review_id == ^review.id,
          order_by: [desc: p.number],
          limit: 1,
          select: p.id
      )

    %Thread{}
    |> Thread.changeset(%{
      review_id: review.id,
      originating_patchset_id: originating_patchset_id,
      author_id: author.id,
      file_path: file_path,
      side: side,
      anchor: anchor,
      status: "open"
    })
    |> Repo.insert!()
  end

  defp upsert_draft_comment(%Thread{id: thread_id}, %User{id: author_id}, body) do
    case Repo.one(
           from c in Comment,
             where:
               c.thread_id == ^thread_id and c.author_id == ^author_id and c.state == "draft",
             limit: 1
         ) do
      nil ->
        %Comment{}
        |> Comment.changeset(%{
          thread_id: thread_id,
          author_id: author_id,
          body: body,
          state: "draft"
        })
        |> Repo.insert!()

      %Comment{} = existing ->
        existing
        |> Comment.changeset(%{body: body})
        |> Repo.update!()
    end
  end

  @doc """
  Deletes one of this author's draft Comments. Also deletes the thread if
  removing this comment leaves it empty (no other comments at all).
  """
  def delete_draft(comment_id, %User{id: author_id}) when is_integer(comment_id) do
    case Repo.get(Comment, comment_id) do
      %Comment{author_id: ^author_id, state: "draft"} = comment ->
        Repo.transaction(fn ->
          Repo.delete!(comment)

          remaining =
            Repo.one(
              from c in Comment, where: c.thread_id == ^comment.thread_id, select: count(c.id)
            )

          if remaining == 0 do
            case Repo.get(Thread, comment.thread_id) do
              %Thread{} = t -> Repo.delete!(t)
              _ -> :ok
            end
          end

          :ok
        end)

      _ ->
        {:error, :not_found}
    end
  end

  ## Publishing

  @doc """
  Publishes every draft Comment authored by `author` on `review` in one
  transaction. Also flips the optional draft ReviewSummary for this round.
  Returns `{:ok, %{comments: [...], summary: nil | s, threads: [...]}}`.

  Broadcasts `{:thread_published, thread}` on `"review:<slug>"` for each
  thread that has a newly-published comment so other open LiveViews can
  refresh the React island.
  """
  def publish_all_drafts(%Review{} = review, %User{} = author, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    summary_body = opts |> Keyword.get(:summary) |> presence()
    round_number = round_number_for(review)

    drafts =
      Repo.all(
        from c in Comment,
          join: t in assoc(c, :thread),
          where: c.state == "draft" and c.author_id == ^author.id and t.review_id == ^review.id,
          preload: [thread: t]
      )

    multi =
      drafts
      |> Enum.reduce(Multi.new(), fn comment, multi ->
        Multi.update(
          multi,
          {:comment, comment.id},
          Comment.changeset(comment, %{state: "published", published_at: now})
        )
      end)
      |> maybe_publish_summary(review, author, round_number, summary_body, now)

    case Repo.transaction(multi) do
      {:ok, results} ->
        published_comments =
          results
          |> Enum.filter(fn {k, _} -> match?({:comment, _}, k) end)
          |> Enum.map(fn {_, v} -> v end)

        threads =
          drafts
          |> Enum.map(& &1.thread)
          |> Enum.uniq_by(& &1.id)
          # Re-load to get fresh comments
          |> Enum.map(
            &Repo.preload(&1, comments: from(c in Comment, where: c.state == "published"))
          )

        published_summary =
          case Map.get(results, :summary) do
            %ReviewSummary{} = s -> s
            _ -> nil
          end

        for thread <- threads do
          Phoenix.PubSub.broadcast(
            @pubsub,
            "review:#{review.slug}",
            {:thread_published, thread}
          )
        end

        {:ok,
         %{
           comments: published_comments,
           summary: published_summary,
           threads: threads
         }}

      {:error, _step, changeset, _} ->
        {:error, changeset}
    end
  end

  defp maybe_publish_summary(multi, _review, _author, _round, nil, _now), do: multi

  defp maybe_publish_summary(multi, review, author, round, body, now) do
    existing = get_draft_summary(review, author, round)

    changeset =
      case existing do
        nil ->
          ReviewSummary.changeset(%ReviewSummary{}, %{
            review_id: review.id,
            author_id: author.id,
            round_number: round,
            body: body,
            state: "published",
            published_at: now
          })

        %ReviewSummary{} = s ->
          ReviewSummary.changeset(s, %{
            body: body,
            state: "published",
            published_at: now
          })
      end

    case existing do
      nil -> Multi.insert(multi, :summary, changeset)
      _ -> Multi.update(multi, :summary, changeset)
    end
  end

  defp round_number_for(%Review{id: review_id}) do
    Repo.one(
      from p in Reviews.Reviews.Patchset,
        where: p.review_id == ^review_id,
        select: max(p.number)
    ) || 1
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc false
  # Exposed for tests + future use.
  def __types__, do: %{thread: Thread, comment: Comment, summary: ReviewSummary}
end
