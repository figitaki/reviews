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
        preload: [comments: ^comments_query, author: []]

    Repo.all(query)
    |> Enum.filter(fn thread -> thread.comments != [] end)
    |> Repo.preload(comments: :author)
  end

  ## Commenting

  @doc """
  Creates a published comment in one transaction.

  When `"thread_id"` belongs to the review, the comment is appended to that
  thread. Otherwise a new thread is created from `"file_path"`, `"side"`, and
  `"thread_anchor"`.

  `params`:

      %{
        "file_path"     => "lib/foo.ex",
        "side"          => "old" | "new",
        "body"          => "...",
        "thread_anchor" => %{"granularity" => "line" | "token_range", ...},
        "thread_id"     => 123 # optional
      }

  Token-range anchors carry the substring identification. The relocator in
  `Reviews.Anchoring` still returns `:not_implemented` for them, so they do not
  survive a patchset push yet. They're stored verbatim and rendered as line
  anchors today via `anchor.line_number_hint`.

  Returns `{:ok, %{thread: t, comment: c}}` or `{:error, reason}`.
  Broadcasts `{:thread_published, thread}` on `"review:<slug>"`.
  """
  def publish_comment(%Review{} = review, %Identity{} = author, params) when is_map(params) do
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

      anchor["granularity"] not in ["line", "token_range"] ->
        {:error, :unknown_granularity}

      true ->
        result =
          Repo.transaction(fn ->
            thread = fetch_or_create_thread(review, author, thread_id, file_path, side, anchor)

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
  rescue
    error in [Ecto.InvalidChangesetError, Postgrex.Error] -> {:error, error}
  end

  def publish_comment(%Review{} = review, %User{} = user, params) when is_map(params) do
    with {:ok, identity} <- Accounts.ensure_human_identity(user) do
      publish_comment(review, identity, params)
    end
  end

  defp comments_query do
    from c in Comment,
      order_by: [asc: c.inserted_at],
      preload: [:author]
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
    originating_patchset_id = ReviewsContext.latest_patchset_id(review)

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

  @doc false
  # Exposed for tests + future use.
  def __types__, do: %{thread: Thread, comment: Comment}
end
