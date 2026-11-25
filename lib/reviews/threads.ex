defmodule Reviews.Threads do
  @moduledoc """
  The Threads context: discussion threads and published comments.

  Comments are one-off published events. Creating a comment either starts a new
  thread from a diff anchor or appends to an existing thread, then broadcasts
  the updated thread on `"review:<slug>"` so open LiveViews update without a
  refresh.
  """
  import Ecto.Query, warn: false

  require Logger

  alias Reviews.Accounts
  alias Reviews.Accounts.{Identity, User}
  alias Reviews.Policy
  alias Reviews.Principal
  alias Reviews.Repo
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.Review
  alias Reviews.Threads.{Comment, Thread}

  @pubsub Reviews.PubSub

  # Every comment reader preloads the same associations, so renaming one (such
  # as the attribution link) is a single change here, not one per query.
  @comment_preloads [:author, :oauth_grant]

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
        order_by: [asc: c.inserted_at, asc: c.id]

    query =
      from t in Thread,
        where: t.review_id == ^review_id,
        order_by: [asc: t.inserted_at, asc: t.id],
        preload: [comments: ^comments_query, author: [], resolved_by: []]

    Repo.all(query)
    |> Enum.filter(fn thread -> thread.comments != [] end)
    |> Repo.preload(comments: @comment_preloads)
  end

  @doc "Thread counts by status, such as `%{\"open\" => 2}`."
  def count_by_status(%Review{id: review_id}) do
    Repo.all(
      from t in Thread,
        where: t.review_id == ^review_id,
        group_by: t.status,
        select: {t.status, count(t.id)}
    )
    |> Map.new()
  end

  @doc """
  One page of threads in id order, after `after_id`, with authors preloaded.

  Filters: `:max_origin_number` (required; threads started on later revisions
  are left out), `:status`, and `:path`.
  """
  def list_thread_page(%Review{id: review_id}, filters, after_id, limit) do
    review_id
    |> filtered_threads(filters)
    |> where([t], t.id > ^after_id)
    |> order_by([t], asc: t.id)
    |> limit(^limit)
    |> preload([:author, :resolved_by])
    |> Repo.all()
  end

  def count_threads(%Review{id: review_id}, filters) do
    review_id |> filtered_threads(filters) |> Repo.aggregate(:count)
  end

  defp filtered_threads(review_id, filters) do
    max_origin = Keyword.fetch!(filters, :max_origin_number)

    query =
      from t in Thread,
        join: p in assoc(t, :originating_patchset),
        where: t.review_id == ^review_id and p.number <= ^max_origin

    query =
      if status = filters[:status], do: where(query, [t], t.status == ^status), else: query

    if path = filters[:path], do: where(query, [t], t.file_path == ^path), else: query
  end

  @doc "A thread of this review, with its author and resolver, or `{:error, :not_found}`."
  def get_review_thread(%Review{id: review_id}, thread_id) do
    with {:ok, id} <- cast_thread_id(thread_id),
         %Thread{} = thread <- Repo.get_by(Thread, id: id, review_id: review_id) do
      {:ok, Repo.preload(thread, [:author, :resolved_by])}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Comments of a thread in id order, after `after_id`, with authors."
  def list_comment_page(thread_id, after_id, limit) do
    Repo.all(
      from c in Comment,
        where: c.thread_id == ^thread_id and c.id > ^after_id,
        order_by: [asc: c.id],
        limit: ^limit,
        preload: ^@comment_preloads
    )
  end

  def comment_counts([]), do: %{}

  def comment_counts(thread_ids) do
    Repo.all(
      from c in Comment,
        where: c.thread_id in ^thread_ids,
        group_by: c.thread_id,
        select: {c.thread_id, count(c.id)}
    )
    |> Map.new()
  end

  def open_counts_by_path(%Review{id: review_id}, paths) do
    Repo.all(
      from t in Thread,
        where: t.review_id == ^review_id and t.status == "open" and t.file_path in ^paths,
        group_by: t.file_path,
        select: {t.file_path, count(t.id)}
    )
    |> Map.new()
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

  New threads may supply `"revision"` or `"originating_patchset_id"` (or atom keys) to
  comment on an explicitly selected revision. It must belong to this review;
  omitted values default to the latest patchset. Replies retain their origin.
  Token-range anchors retain their selected text and offset across projection.

  Returns `{:ok, %{thread: t, comment: c}}` or `{:error, reason}`.
  Broadcasts `{:thread_published, thread}` on `"review:<slug>"`.
  """
  def publish_comment(review, author, params, attribution \\ nil)

  # Surfaces pass a principal: the policy decides whether it may comment, and
  # its identity and attribution are recorded on the comment.
  def publish_comment(%Review{} = review, %Principal{} = principal, params, nil)
      when is_map(params) do
    if Policy.can?(principal, :comment, review),
      do: publish_comment(review, principal.identity, params, principal.attribution),
      else: {:error, :forbidden}
  end

  def publish_comment(%Review{} = review, %Identity{} = author, params, attribution)
      when is_map(params) do
    case Map.get(params, "thread_id", params[:thread_id]) do
      nil -> start_thread(review, author, params, attribution)
      thread_id -> reply(review, author, thread_id, params["body"] || params[:body], attribution)
    end
  end

  def publish_comment(%Review{} = review, %User{} = user, params, attribution)
      when is_map(params) do
    with {:ok, identity} <- Accounts.ensure_human_identity(user) do
      publish_comment(review, identity, params, attribution)
    end
  end

  @doc "Reply using only a review-scoped thread ID and body; location and origin are inherited."
  def reply(review, author, thread_id, body, attribution \\ nil)

  def reply(%Review{} = review, %Identity{} = author, thread_id, body, attribution) do
    body = if is_binary(body), do: String.trim(body), else: ""

    with false <- body == "",
         {:ok, %Thread{} = thread} <- fetch_reply_thread(review, thread_id) do
      insert_comment(
        review,
        author,
        thread,
        thread.file_path,
        thread.side,
        thread.anchor,
        body,
        thread.originating_patchset_id,
        attribution
      )
    else
      true -> {:error, :empty_body}
      {:ok, nil} -> {:error, :thread_not_found}
      error -> error
    end
  end

  @doc "Start a thread on a validated line of the selected immutable revision."
  def start_thread(%Review{} = review, %Identity{} = author, params, attribution \\ nil) do
    file_path = params["file_path"] || params[:file_path]
    side = params["side"] || params[:side]
    body = params["body"] || params[:body]
    body = if is_binary(body), do: String.trim(body), else: ""
    anchor = params["thread_anchor"] || params[:thread_anchor] || %{}

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
        with {:ok, origin_id} <- originating_patchset_id(review, params),
             :ok <- validate_new_thread(review, author, file_path, side, anchor, origin_id),
             {:ok, anchor} <-
               Reviews.Anchoring.validate_anchor(%{id: origin_id}, file_path, side, anchor) do
          insert_comment(
            review,
            author,
            nil,
            file_path,
            side,
            anchor,
            body,
            origin_id,
            attribution
          )
        end
    end
  end

  defp insert_comment(
         review,
         author,
         existing,
         file_path,
         side,
         anchor,
         body,
         origin_id,
         attribution
       ) do
    result =
      Repo.transaction(fn ->
        thread = existing || create_thread(review, author, file_path, side, anchor, origin_id)

        comment =
          %Comment{}
          |> Comment.changeset(%{
            thread_id: thread.id,
            author_id: author.id,
            body: body,
            oauth_grant_id: attribution && attribution["link_id"],
            attribution: attribution
          })
          |> insert_or_rollback()

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
  rescue
    error in Postgrex.Error ->
      Logger.error("publish_comment failed: " <> Exception.message(error))
      {:error, :could_not_publish}
  end

  @doc """
  Updates a thread's review status.

  Resolving records the acting identity and timestamp. Reopening clears both. The
  thread must belong to the supplied review, or this returns `{:error, :not_found}`.
  Only the review owner or the thread's author may change it (`Reviews.Policy`);
  anyone else gets `{:error, :forbidden}`, even when the status would not change.
  """
  def update_status(%Review{} = review, thread_id, actor, status)
      when status in ["open", "resolved"] and
             (is_struct(actor, Identity) or is_struct(actor, Principal)) do
    identity = Principal.from(actor).identity

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
               nil ->
                 Repo.rollback(:not_found)

               %Thread{} = thread ->
                 cond do
                   not Policy.can?(actor, {:update_thread_status, thread}, review) ->
                     Repo.rollback(:forbidden)

                   thread.status == status ->
                     {thread, false}

                   true ->
                     {write_status(thread, identity, status), true}
                 end
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

  def update_status(%Review{}, _thread_id, actor, _status)
      when is_struct(actor, Identity) or is_struct(actor, Principal),
      do: {:error, :invalid_status}

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
      order_by: [asc: c.inserted_at, asc: c.id],
      preload: ^@comment_preloads
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

  defp originating_patchset_id(review, params) do
    revision = Map.get(params, "revision", params[:revision])
    id = Map.get(params, "originating_patchset_id", params[:originating_patchset_id])

    cond do
      not is_nil(revision) and not is_nil(id) ->
        {:error, :patchset_not_found}

      not is_nil(revision) ->
        with true <- is_integer(revision) and revision > 0 and revision <= 2_147_483_647,
             %Reviews.Reviews.Patchset{id: id} <-
               ReviewsContext.get_patchset_by_number(review, revision) do
          {:ok, id}
        else
          _ -> {:error, :patchset_not_found}
        end

      not is_nil(id) ->
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

      true ->
        case ReviewsContext.latest_patchset_id(review) do
          nil -> {:error, :patchset_not_found}
          id -> {:ok, id}
        end
    end
  end

  defp create_thread(review, author, file_path, side, anchor, origin_id) do
    thread_changeset(review, author, file_path, side, anchor, origin_id)
    |> insert_or_rollback()
  end

  defp validate_new_thread(review, author, file_path, side, anchor, origin_id) do
    case thread_changeset(review, author, file_path, side, anchor, origin_id) do
      %Ecto.Changeset{valid?: true} -> :ok
      changeset -> {:error, changeset}
    end
  end

  defp thread_changeset(review, author, file_path, side, anchor, originating_patchset_id) do
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
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end
