defmodule Reviews.Reviews do
  @moduledoc """
  The Reviews context: reviews, patchsets, and per-patchset files.

  This is the only module that should touch `Reviews.Repo` for these entities.
  Controllers/LiveViews go through these functions.
  """
  import Ecto.Query, warn: false

  alias Reviews.Accounts
  alias Reviews.Accounts.{Identity, User}
  alias Reviews.Policy
  alias Reviews.Principal
  alias Reviews.Repo
  alias Reviews.Reviews.{DeletedReview, DeletionHook, File, Patchset, Review}
  alias Reviews.Threads.{Comment, Thread}

  ## Reviews

  @slug_bytes 5

  def get_review_by_slug(slug) when is_binary(slug) do
    Repo.get_by(Review, slug: slug)
  end

  def get_review_by_slug!(slug) when is_binary(slug) do
    Repo.get_by!(Review, slug: slug)
  end

  @doc """
  True when `actor` belongs to the account that owns the review: the author's
  human identity or any agent identity of the same user.
  """
  def owned_by?(%Review{author_id: author_id}, %Identity{owner_user_id: owner_id})
      when not is_nil(owner_id) do
    Repo.exists?(
      from i in Identity,
        where: i.id == ^author_id and i.owner_user_id == ^owner_id
    )
  end

  def owned_by?(%Review{}, _actor), do: false

  ## Deletion

  @doc "True when a review with this slug existed and its owner deleted it."
  def deleted?(slug) when is_binary(slug),
    do: Repo.exists?(from d in DeletedReview, where: d.slug == ^slug)

  @doc """
  Why no review has this slug: `:review_deleted` when its owner deleted it,
  otherwise `:review_not_found`. Surfaces pass it to `Reviews.Errors`.
  """
  def not_found_reason(slug) when is_binary(slug),
    do: if(deleted?(slug), do: :review_deleted, else: :review_not_found)

  @doc """
  What deleting the review would remove, for the confirmation warning:
  counts of patchsets, threads and comments, and the comments written by
  other accounts (people or their agents), with those authors' handles.
  """
  def deletion_summary(%Review{id: review_id, author_id: author_id}) do
    owner_id = Repo.one(from i in Identity, where: i.id == ^author_id, select: i.owner_user_id)

    comments =
      from c in Comment,
        join: t in Thread,
        on: t.id == c.thread_id,
        join: i in Identity,
        on: i.id == c.author_id,
        where: t.review_id == ^review_id

    others = from [_c, _t, i] in comments, where: i.owner_user_id != ^owner_id

    %{
      patchsets: Repo.aggregate(from(p in Patchset, where: p.review_id == ^review_id), :count),
      threads: Repo.aggregate(from(t in Thread, where: t.review_id == ^review_id), :count),
      comments: Repo.aggregate(comments, :count),
      other_comments: Repo.aggregate(others, :count),
      other_authors:
        Repo.all(from [_c, _t, i] in others, distinct: true, select: i.handle, order_by: i.handle)
    }
  end

  @doc """
  Permanently deletes a review and everything it owns: patchsets and their
  files and packets, threads and every comment on them (other people's
  included), section decisions and viewed-hunk state. Only the review owner's
  account may delete. Keeps the slug in `deleted_reviews` so the link can say
  the review was deleted.

  Runs `Reviews.Reviews.DeletionHook`s in the same transaction. Broadcasts
  `{:review_deleted, slug}` on `"review:<slug>"` after it commits.

  Returns `{:ok, review}`, `{:error, :forbidden}` without writing, or
  `{:error, :review_deleted}` when another request deleted it first.
  """
  def delete_review(%Review{} = review, actor) do
    if Policy.can?(actor, :delete, review) do
      review |> delete_review_transaction() |> broadcast_deleted()
    else
      {:error, :forbidden}
    end
  end

  defp delete_review_transaction(%Review{id: id, slug: slug}) do
    Repo.transaction(fn ->
      # The row lock makes concurrent comments and pushes, whose foreign keys
      # need this row, wait for the deletion and then fail.
      with %Review{} = review <-
             Repo.one(from r in Review, where: r.id == ^id, lock: "FOR UPDATE"),
           :ok <- DeletionHook.run(review) do
        # Threads first: their originating patchset references are RESTRICT,
        # so deleting them explicitly keeps the patchset cascade from depending
        # on the order Postgres runs cascades in. Comments cascade from threads;
        # patchsets, files, section decisions and viewed-hunk rows cascade
        # from the review.
        Repo.delete_all(from t in Thread, where: t.review_id == ^id)
        Repo.delete!(review)

        Repo.insert!(
          %DeletedReview{slug: slug, deleted_at: DateTime.utc_now(:second)},
          on_conflict: {:replace, [:deleted_at]},
          conflict_target: :slug
        )

        review
      else
        nil -> Repo.rollback(:review_deleted)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp broadcast_deleted({:ok, %Review{slug: slug}} = result) do
    Phoenix.PubSub.broadcast(Reviews.PubSub, "review:#{slug}", {:review_deleted, slug})
    result
  end

  defp broadcast_deleted(error), do: error

  @doc """
  Reviews the actor's account owns whose title, description, or slug contains
  `query` (any case), newest first, at most `limit`. A blank query lists the
  newest.
  """
  def search_owned_reviews(%Identity{owner_user_id: owner_id}, query, limit)
      when is_binary(query) and is_integer(limit) do
    pattern = "%" <> String.replace(String.trim(query), ~r/[\\%_]/, "\\\\\\0") <> "%"

    Repo.all(
      from r in Review,
        join: i in Identity,
        on: i.id == r.author_id,
        where: i.owner_user_id == ^owner_id,
        where:
          ilike(r.title, ^pattern) or ilike(coalesce(r.description, ""), ^pattern) or
            ilike(r.slug, ^pattern),
        order_by: [desc: r.updated_at, desc: r.id],
        limit: ^limit,
        # Descriptions have no length limit; the results need only these.
        select: struct(r, [:id, :slug, :title, :updated_at])
    )
  end

  @doc """
  Lists the reviews `viewer` wrote or took part in. See `Reviews.ReviewIndex`
  for the filters, the visibility rule, and the result shape.
  """
  defdelegate list_reviews(viewer, filters \\ %{}), to: Reviews.ReviewIndex, as: :list

  @doc """
  Creates a review along with its initial patchset (#1) in a single transaction.

  Returns `{:ok, %{review: review, patchset: patchset, files: files}}` or
  `{:error, step, changeset, _}`.

  Populates per-file rows from the raw unified diff in the same transaction so
  the LiveView sidebar can render without re-parsing on each load.
  """
  def create_review_with_initial_patchset(%Identity{} = author, attrs) when is_map(attrs) do
    slug = attrs[:slug] || attrs["slug"] || generate_slug()
    raw_diff = attrs[:raw_diff] || attrs["raw_diff"]
    code_snapshot_id = attrs[:code_snapshot_id] || attrs["code_snapshot_id"]

    review_attrs = %{
      slug: slug,
      title: attrs[:title] || attrs["title"],
      description: attrs[:description] || attrs["description"],
      author_id: author.id
    }

    patchset_attrs = %{
      number: 1,
      raw_diff: raw_diff,
      packet: Map.get(attrs, :packet, attrs["packet"]),
      base_sha: attrs[:base_sha] || attrs["base_sha"],
      branch_name: attrs[:branch_name] || attrs["branch_name"],
      pushed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:review, Review.changeset(%Review{}, review_attrs))
    |> Ecto.Multi.insert(:patchset, fn %{review: review} ->
      Patchset.changeset(%Patchset{}, Map.put(patchset_attrs, :review_id, review.id))
    end)
    |> Ecto.Multi.run(:files, fn _repo, %{patchset: patchset} ->
      insert_files_for_patchset(patchset, raw_diff, attrs)
    end)
    |> Ecto.Multi.run(:code_snapshot, fn _repo, %{review: review, patchset: patchset} ->
      Reviews.CodeSnapshots.maybe_claim(author, review, patchset, code_snapshot_id)
    end)
    |> Repo.transaction()
  end

  def create_review_with_initial_patchset(%User{} = user, attrs) when is_map(attrs) do
    with {:ok, identity} <- Accounts.ensure_human_identity(user) do
      create_review_with_initial_patchset(identity, attrs)
    end
  end

  ## Patchsets

  @doc """
  Appends a patchset on behalf of an authenticated identity. Only identities
  owned by the review author's user may upload revisions. There is currently
  no editor grant model; link access does not grant revision upload access.

  Returns `{:error, :forbidden}` without writing when the actor is not an owner.
  Otherwise returns `{:ok, %{patchset: patchset, code_snapshot: result}}`, where
  `result` is `nil`, a claimed snapshot, or `{:skipped, code}`.
  """
  def append_patchset(%Review{} = review, actor, attrs) when is_map(attrs) do
    if Policy.can?(actor, :push, review),
      do: insert_patchset(Principal.from(actor).identity, review, attrs),
      else: {:error, :forbidden}
  end

  @doc """
  Appends a new patchset to an existing review. Auto-numbers to (max+1).
  Also populates the per-file rows for the new patchset so the sidebar
  renders without a re-parse.

  Trusted setup path (seeds, demos, tests) that skips `Reviews.Policy`. Every
  surface must use `append_patchset/3` with the authenticated principal.
  Returns `{:ok, patchset}`; with no pusher identity it never claims a code
  snapshot.
  """
  def append_patchset_unchecked(%Review{} = review, attrs) when is_map(attrs) do
    with {:ok, %{patchset: patchset}} <- insert_patchset(nil, review, attrs),
         do: {:ok, patchset}
  end

  defp insert_patchset(identity, %Review{} = review, attrs) do
    next_number = next_patchset_number(review.id)
    raw_diff = attrs[:raw_diff] || attrs["raw_diff"]
    code_snapshot_id = attrs[:code_snapshot_id] || attrs["code_snapshot_id"]

    patchset_attrs = %{
      review_id: review.id,
      number: next_number,
      raw_diff: raw_diff,
      packet: Map.get(attrs, :packet, attrs["packet"]),
      base_sha: attrs[:base_sha] || attrs["base_sha"],
      branch_name: attrs[:branch_name] || attrs["branch_name"],
      pushed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:patchset, Patchset.changeset(%Patchset{}, patchset_attrs))
    |> Ecto.Multi.run(:files, fn _repo, %{patchset: patchset} ->
      insert_files_for_patchset(patchset, raw_diff, attrs)
    end)
    |> Ecto.Multi.run(:code_snapshot, fn _repo, %{patchset: patchset} ->
      maybe_claim_snapshot(identity, review, patchset, code_snapshot_id)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{patchset: patchset, code_snapshot: code_snapshot}} ->
        Phoenix.PubSub.broadcast(
          Reviews.PubSub,
          "review:#{review.slug}",
          {:patchset_pushed, patchset.number}
        )

        {:ok, %{patchset: patchset, code_snapshot: code_snapshot}}

      {:error, _step, %Ecto.Changeset{} = changeset, _} ->
        {:error, changeset}

      {:error, :code_snapshot, code, _} when is_atom(code) ->
        {:error, {:code_snapshot, code}}

      {:error, _step, reason, _} ->
        {:error, reason}
    end
  end

  defp maybe_claim_snapshot(_identity, _review, _patchset, nil), do: {:ok, nil}

  defp maybe_claim_snapshot(%Identity{} = identity, review, patchset, code_snapshot_id) do
    Reviews.CodeSnapshots.maybe_claim(identity, review, patchset, code_snapshot_id)
  end

  # A snapshot id without a known pusher identity can never claim.
  defp maybe_claim_snapshot(nil, _review, _patchset, _code_snapshot_id) do
    case Reviews.CodeStorage.policy() do
      :required -> {:error, :snapshot_not_authorized}
      _optional -> {:ok, {:skipped, :snapshot_not_authorized}}
    end
  end

  def list_patchsets(%Review{id: review_id}) do
    Repo.all(
      from p in Patchset,
        where: p.review_id == ^review_id,
        order_by: [asc: p.number],
        preload: [:code_snapshot]
    )
  end

  def get_patchset!(id), do: Repo.get!(Patchset, id)

  def get_patchset_by_number(%Review{id: review_id}, number) when is_integer(number) do
    Repo.get_by(Patchset, review_id: review_id, number: number)
  end

  @doc "Select one revision's identity without loading its diff, packet or file totals."
  def get_patchset_metadata(%Review{id: review_id}, number) do
    query =
      from p in Patchset,
        where: p.review_id == ^review_id,
        order_by: [desc: p.number],
        limit: 1,
        select: %{id: p.id, number: p.number}

    query = if is_nil(number), do: query, else: from(p in query, where: p.number == ^number)
    Repo.one(query)
  end

  @doc "Revision identities for a page's thread origins, scoped to their review."
  def list_patchset_metadata(%Review{id: review_id}, ids) when is_list(ids) do
    Repo.all(
      from p in Patchset,
        where: p.review_id == ^review_id and p.id in ^ids,
        select: %{id: p.id, number: p.number}
    )
  end

  @doc "The packet of one patchset, without loading its diff."
  def get_packet(%{id: patchset_id}) do
    Repo.one(from p in Patchset, where: p.id == ^patchset_id, select: p.packet)
  end

  def get_file(%{id: patchset_id}, path) when is_binary(path) do
    Repo.get_by(File, patchset_id: patchset_id, path: path)
  end

  @doc """
  Revision metadata without diffs or packets, oldest first, with file and line
  totals from the stored file rows. For readers that must not load every
  revision's raw diff.
  """
  def list_patchset_summaries(%Review{id: review_id}) do
    stats =
      from f in File,
        join: p in Patchset,
        on: p.id == f.patchset_id,
        where: p.review_id == ^review_id,
        group_by: f.patchset_id,
        select: %{
          patchset_id: f.patchset_id,
          files: count(f.id),
          additions: coalesce(sum(f.additions), 0),
          deletions: coalesce(sum(f.deletions), 0)
        }

    Repo.all(
      from p in Patchset,
        where: p.review_id == ^review_id,
        left_join: s in subquery(stats),
        on: s.patchset_id == p.id,
        order_by: [asc: p.number],
        select: %{
          id: p.id,
          number: p.number,
          pushed_at: p.pushed_at,
          branch_name: p.branch_name,
          base_sha: p.base_sha,
          packet_present: not is_nil(p.packet),
          stats: %{
            files: coalesce(s.files, 0),
            additions: coalesce(s.additions, 0),
            deletions: coalesce(s.deletions, 0)
          }
        }
    )
  end

  def latest_patchset(%Review{id: review_id}) do
    Repo.one(
      from p in Patchset,
        where: p.review_id == ^review_id,
        order_by: [desc: p.number],
        limit: 1
    )
  end

  def latest_patchset_id(%Review{} = review) do
    case latest_patchset(review) do
      %Patchset{id: id} -> id
      nil -> nil
    end
  end

  def list_files(%Patchset{id: patchset_id}) do
    Repo.all(from f in File, where: f.patchset_id == ^patchset_id, order_by: [asc: f.path])
  end

  def list_files(%{id: patchset_id}, paths) when is_list(paths) do
    Repo.all(
      from f in File,
        where: f.patchset_id == ^patchset_id and f.path in ^paths,
        order_by: [asc: f.path]
    )
  end

  @doc "File metadata of a revision without diffs, in path order, one page at a time."
  def list_file_summaries(%{id: patchset_id}, offset, limit) do
    Repo.all(
      from f in File,
        where: f.patchset_id == ^patchset_id,
        order_by: [asc: f.path],
        offset: ^offset,
        limit: ^limit,
        select: %{
          path: f.path,
          old_path: f.old_path,
          status: f.status,
          additions: f.additions,
          deletions: f.deletions,
          bytes: coalesce(fragment("octet_length(?)", f.raw_diff), 0)
        }
    )
  end

  defp next_patchset_number(review_id) do
    (Repo.one(from p in Patchset, where: p.review_id == ^review_id, select: max(p.number)) || 0) +
      1
  end

  defp generate_slug do
    :crypto.strong_rand_bytes(@slug_bytes * 2)
    |> Base.url_encode64(padding: false)
    |> String.replace(~r/[^A-Za-z0-9]/, "")
    |> String.slice(0, 8)
  end

  # --- Diff parsing -------------------------------------------------------

  @doc """
  Returns a list of `%{path, old_path, status, additions, deletions, raw_diff}` parsed
  out of a unified `git diff` string. Exposed for the LiveView so it can
  display +/- counts without re-querying the DB rows. Pure function.
  """
  @spec parse_diff_files(String.t() | nil) :: [map()]
  def parse_diff_files(nil), do: []
  def parse_diff_files(""), do: []

  def parse_diff_files(raw_diff) when is_binary(raw_diff) do
    # Split on `diff --git ` boundaries, keeping each chunk.
    raw_diff
    |> String.split(~r/^diff --git /m, trim: true)
    |> Enum.map(&parse_one_file_chunk("diff --git " <> &1))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_one_file_chunk(raw_chunk) do
    chunk = String.trim_leading(raw_chunk, "diff --git ")
    lines = String.split(chunk, "\n")
    header_line = List.first(lines) || ""

    # Header looks like:  a/lib/foo.ex b/lib/foo.ex
    {old_path, new_path} =
      case Reviews.GitDiffPaths.parse(header_line) do
        {:ok, o, n} -> {o, n}
        _ -> {nil, nil}
      end

    cond do
      is_nil(new_path) ->
        nil

      true ->
        status = detect_status(chunk, old_path, new_path)
        {additions, deletions} = count_hunk_changes(lines)
        path = if status == "deleted", do: old_path, else: new_path

        %{
          path: path,
          old_path: if(status in ["renamed", "deleted"], do: old_path),
          status: status,
          additions: additions,
          deletions: deletions,
          raw_diff: raw_chunk
        }
    end
  end

  defp detect_status(chunk, old_path, new_path) do
    cond do
      String.contains?(chunk, "\nnew file mode") -> "added"
      String.contains?(chunk, "\ndeleted file mode") -> "deleted"
      old_path != new_path -> "renamed"
      true -> "modified"
    end
  end

  # File headers (`--- a/`, `+++ b/`) only come before the first `@@`; inside a
  # hunk, a row like `--- note` is a removed `-- note` line.
  defp count_hunk_changes(lines) do
    lines
    |> Enum.drop_while(&(not String.starts_with?(&1, "@@ ")))
    |> Enum.reduce({0, 0}, fn line, {adds, dels} ->
      cond do
        String.starts_with?(line, "+") -> {adds + 1, dels}
        String.starts_with?(line, "-") -> {adds, dels + 1}
        true -> {adds, dels}
      end
    end)
  end

  defp insert_files_for_patchset(%Patchset{id: patchset_id}, raw_diff, push_attrs) do
    flags = file_flags(push_attrs[:file_attributes] || push_attrs["file_attributes"])

    files =
      raw_diff
      |> parse_diff_files()
      |> Enum.map(fn meta ->
        file_flags = Map.get(flags, meta.path, %{})

        attrs = %{
          patchset_id: patchset_id,
          path: meta.path,
          old_path: meta.old_path,
          status: meta.status,
          additions: meta.additions,
          deletions: meta.deletions,
          raw_diff: meta.raw_diff,
          generated: Map.get(file_flags, "generated") == true,
          vendored: Map.get(file_flags, "vendored") == true
        }

        case %File{} |> File.changeset(attrs) |> Repo.insert() do
          {:ok, file} -> {:ok, file}
          {:error, changeset} -> {:halt, changeset}
        end
      end)

    case Enum.find(files, &match?({:halt, _}, &1)) do
      {:halt, changeset} -> {:error, changeset}
      nil -> {:ok, Enum.map(files, fn {:ok, f} -> f end)}
    end
  end

  # `file_attributes` from the CLI: a list of `%{"path" => ..., "generated" =>
  # bool, "vendored" => bool}`, only for flagged files. Anything else is
  # ignored; the flags only change how the page first shows a file.
  defp file_flags(list) when is_list(list) do
    for %{"path" => path} = entry <- list, is_binary(path), into: %{} do
      {path, Map.take(entry, ["generated", "vendored"])}
    end
  end

  defp file_flags(_), do: %{}

  @doc """
  Returns the raw chunk for a single file inside a patchset (the substring
  between two `diff --git` markers). Used by the LiveView to pass per-file
  diff payloads to the Pierre renderer so each file mounts independently.
  """
  @spec raw_diff_for_file(Patchset.t(), String.t()) :: String.t() | nil
  def raw_diff_for_file(%Patchset{raw_diff: nil}, _path), do: nil
  def raw_diff_for_file(%Patchset{raw_diff: ""}, _path), do: nil

  def raw_diff_for_file(%Patchset{raw_diff: raw_diff}, path) when is_binary(path) do
    # Re-split, prepend "diff --git " back onto each chunk, and find the
    # chunk whose header references this path.
    chunks = String.split(raw_diff, ~r/^diff --git /m, trim: true)

    Enum.find_value(chunks, fn chunk ->
      header = chunk |> String.split("\n", parts: 2) |> List.first()

      case Reviews.GitDiffPaths.parse(header || "") do
        {:ok, old_path, new_path} when path == old_path or path == new_path ->
          "diff --git " <> chunk

        _ ->
          nil
      end
    end)
  end
end
