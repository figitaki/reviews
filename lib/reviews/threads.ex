defmodule Reviews.Threads do
  @moduledoc """
  The Threads context: discussion threads and published comments.

  Comments are one-off published events. Creating a comment either starts a new
  thread from a diff anchor or appends to an existing thread, then broadcasts
  the updated thread on `"review:<slug>"` so open LiveViews update without a
  refresh.
  """
  import Ecto.Query, warn: false

  alias Reviews.Accounts
  alias Reviews.Accounts.{Identity, User}
  alias Reviews.Repo
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.Review
  alias Reviews.Threads.{Comment, Thread}

  @pubsub Reviews.PubSub

  # Postgres bigint. An id past this range reaches the driver as an unencodable
  # integer and takes the whole request down, so it is a miss like any other.
  @max_thread_id 9_223_372_036_854_775_807

  ## Queries

  @doc """
  All visible threads for a review, with comments preloaded and ordered.
  """
  def list_published_threads(review_id) when is_integer(review_id) do
    comments_query =
      from c in Comment,
        order_by: [asc: c.inserted_at]

    query =
      from t in Thread,
        where: t.review_id == ^review_id,
        order_by: [asc: t.inserted_at],
        preload: [comments: ^comments_query, author: [], resolved_by: []]

    Repo.all(query)
    |> Enum.filter(fn thread -> thread.comments != [] end)
    |> Repo.preload(comments: :author)
  end

  @doc """
  Published comment activity for a review, one entry per comment author.

  Returns `%{author: Identity.t(), comment_count: integer, last_commented_at:
  DateTime.t()}` maps. `Reviews.ReviewDeciders` merges these with section
  decisions to build the published reviewers list.
  """
  def list_comment_authors(review_id) when is_integer(review_id) do
    rows =
      Repo.all(
        from c in Comment,
          join: t in assoc(c, :thread),
          where: t.review_id == ^review_id,
          group_by: c.author_id,
          select: {c.author_id, count(c.id), max(c.inserted_at)}
      )

    author_ids = Enum.map(rows, &elem(&1, 0))

    authors_by_id =
      Repo.all(from i in Identity, where: i.id in ^author_ids)
      |> Map.new(&{&1.id, &1})

    Enum.map(rows, fn {author_id, comment_count, last_commented_at} ->
      %{
        author: Map.fetch!(authors_by_id, author_id),
        comment_count: comment_count,
        last_commented_at: last_commented_at
      }
    end)
  end

  ## Commenting

  @doc """
  Creates a published comment in one transaction.

  When `"thread_id"` is given, the comment is appended to that thread. If the
  id is not a thread of this review, it returns `{:error, :thread_not_found}`
  and writes nothing. Without `"thread_id"`, a new thread is created from
  `"file_path"`, `"side"`, and `"thread_anchor"`.

  `params`:

      %{
        "file_path"     => "lib/foo.ex",
        "side"          => "old" | "new",
        "body"          => "...",
        "thread_anchor" => %{"granularity" => "line" | "token_range", ...},
        "thread_id"     => 123 # optional
      }

  New threads may supply `"originating_patchset_id"` (or its atom key) to
  comment on an explicitly selected revision. It must belong to this review;
  omitted values default to the latest patchset. Replies retain their origin.
  Token-range anchors retain their selected text and offset across projection.

  Returns `{:ok, %{thread: t, comment: c}}` or `{:error, reason}`.
  Broadcasts `{:thread_published, thread}` on `"review:<slug>"`.
  """
  def publish_comment(%Review{} = review, %Identity{} = author, params) when is_map(params) do
    file_path = params["file_path"] || params[:file_path]
    side = params["side"] || params[:side]
    body = String.trim(to_string(params["body"] || params[:body] || ""))
    anchor = params["thread_anchor"] || params[:thread_anchor] || %{}
    thread_id = Map.get(params, "thread_id", params[:thread_id])

    cond do
      body == "" ->
        {:error, :empty_body}

      side not in ["old", "new"] ->
        {:error, :invalid_side}

      !is_binary(file_path) or file_path == "" ->
        {:error, :invalid_file_path}

      !is_map(anchor) or not Map.has_key?(anchor, "granularity") ->
        {:error, :invalid_anchor}

      anchor["granularity"] not in ["line", "token_range"] ->
        {:error, :unknown_granularity}

      true ->
        with {:ok, existing} <- fetch_reply_thread(review, thread_id),
             {:ok, origin_id} <- originating_patchset_id(review, existing, params) do
          insert_comment(review, author, existing, file_path, side, anchor, body, origin_id)
        end
    end
  rescue
    error in [Ecto.InvalidChangesetError, Postgrex.Error] -> {:error, error}
  end

  def publish_comment(%Review{} = review, %User{} = user, params) when is_map(params) do
    with {:ok, identity} <- Accounts.ensure_human_identity(user) do
      publish_comment(review, identity, params)
    end
  end

  defp insert_comment(review, author, existing, file_path, side, anchor, body, origin_id) do
    result =
      Repo.transaction(fn ->
        thread = existing || create_thread(review, author, file_path, side, anchor, origin_id)

        comment =
          %Comment{}
          |> Comment.changeset(%{
            thread_id: thread.id,
            author_id: author.id,
            body: body
          })
          |> Repo.insert!()

        %{thread: thread, comment: comment}
      end)

    case result do
      {:ok, %{thread: thread, comment: _} = out} ->
        published_thread = Repo.preload(thread, comments: comments_query())

        Phoenix.PubSub.broadcast(
          @pubsub,
          "review:#{review.slug}",
          {:thread_published, published_thread}
        )

        {:ok, out}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Updates a thread's review status.

  Resolving records the acting identity and timestamp. Reopening clears both. The
  thread must belong to the supplied review.
  """
  def update_status(%Review{} = review, thread_id, %Identity{} = identity, status)
      when status in ["open", "resolved"] do
    with {:ok, id} <- cast_thread_id(thread_id),
         {:ok, {thread, changed?}} <-
           Repo.transaction(fn ->
             # The no-op check and write must share the row lock. A concurrent
             # resolver must see the first transition, not overwrite it.
             case Repo.one(
                    from t in Thread,
                      where: t.id == ^id and t.review_id == ^review.id,
                      lock: "FOR UPDATE"
                  ) do
               %Thread{status: ^status} = thread -> {thread, false}
               %Thread{} = thread -> {write_status(thread, identity, status), true}
               nil -> Repo.rollback(:not_found)
             end
           end) do
      thread = preload_thread(thread)

      if changed? do
        Phoenix.PubSub.broadcast(
          @pubsub,
          "review:#{review.slug}",
          {:thread_updated, thread}
        )
      end

      {:ok, thread}
    end
  end

  def update_status(%Review{} = review, thread_id, %User{} = user, status) do
    with {:ok, identity} <- Accounts.ensure_human_identity(user) do
      update_status(review, thread_id, identity, status)
    end
  end

  def update_status(%Review{}, _thread_id, %Identity{}, _status), do: {:error, :invalid_status}

  defp write_status(thread, identity, status) do
    attrs =
      case status do
        "resolved" ->
          %{
            status: "resolved",
            resolved_by_id: identity.id,
            resolved_at: DateTime.utc_now(:second)
          }

        "open" ->
          %{status: "open", resolved_by_id: nil, resolved_at: nil}
      end

    case thread |> Thread.changeset(attrs) |> Repo.update() do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp preload_thread(%Thread{} = thread) do
    Repo.preload(thread, [:author, :resolved_by, comments: comments_query()])
  end

  defp cast_thread_id(id) when is_integer(id) and id > 0 and id <= @max_thread_id, do: {:ok, id}

  defp cast_thread_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 and parsed <= @max_thread_id -> {:ok, parsed}
      _ -> {:error, :not_found}
    end
  end

  defp cast_thread_id(_id), do: {:error, :not_found}

  defp comments_query do
    from c in Comment,
      order_by: [asc: c.inserted_at],
      preload: [:author]
  end

  # No thread_id starts a new thread. A thread_id that is not a thread of this
  # review (unparseable, out of range, missing, or from another review) is an
  # error, so a bad reply never opens a stray thread.
  defp fetch_reply_thread(_review, nil), do: {:ok, nil}

  defp fetch_reply_thread(%Review{id: review_id}, thread_id) do
    with {:ok, id} <- cast_thread_id(thread_id),
         %Thread{review_id: ^review_id} = thread <- Repo.get(Thread, id) do
      {:ok, thread}
    else
      _ -> {:error, :thread_not_found}
    end
  end

  defp originating_patchset_id(_review, %Thread{} = thread, _params),
    do: {:ok, thread.originating_patchset_id}

  defp originating_patchset_id(review, nil, params) do
    case Map.get(params, "originating_patchset_id", params[:originating_patchset_id]) do
      nil ->
        {:ok, ReviewsContext.latest_patchset_id(review)}

      id ->
        with {:ok, id} <- cast_thread_id(id),
             true <-
               Repo.exists?(
                 from p in Reviews.Reviews.Patchset,
                   where: p.id == ^id and p.review_id == ^review.id
               ) do
          {:ok, id}
        else
          _ -> {:error, :patchset_not_found}
        end
    end
  end

  defp create_thread(review, author, file_path, side, anchor, originating_patchset_id) do
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
end
