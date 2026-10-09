defmodule Reviews.ReviewIndex do
  @moduledoc """
  Lists the reviews a viewer can find again: the review index on `/reviews`,
  `GET /api/v1/reviews`, and `reviews list`.

  ## Who sees what

  A review link is the only key to a `"link"` review. Anyone with the slug can
  open it. So the index never lists reviews by visibility alone. It lists only
  reviews that the viewer's identities wrote or took part in. Taking part means
  a published comment, a section decision, or a viewed hunk.

  The viewer is one of these:

    * `%User{}` covers every identity the user owns (human and agents). The web
      session and human-identity API tokens use this.
    * `%Identity{}` covers that one identity. Agent-identity API tokens use
      this, so an agent token cannot list its owner's other reviews.

  ## Pagination

  Offset pagination with `limit` (default #{25}, max #{100}) and `offset`. The
  result has `next_offset` when more rows exist. Rows are sorted by the latest
  of the review's `updated_at` and its newest patchset push, newest first, with
  the review id as a tie breaker.
  """
  import Ecto.Query, warn: false

  alias Reviews.Accounts
  alias Reviews.Accounts.{Identity, User}
  alias Reviews.Repo
  alias Reviews.Reviews.{PacketHunkView, PacketSectionDecision, Patchset, Review}
  alias Reviews.Threads.{Comment, Thread}

  @default_limit 25
  @max_limit 100
  @roles ~w(all authored involved)
  @statuses ~w(all open updated)

  @type filters :: %{
          role: String.t(),
          status: String.t(),
          author: String.t() | nil,
          q: String.t() | nil,
          limit: pos_integer(),
          offset: non_neg_integer()
        }

  @type entry :: %{
          review: Review.t(),
          role: String.t(),
          patchset_count: non_neg_integer(),
          latest_patchset_number: non_neg_integer() | nil,
          last_pushed_at: DateTime.t() | nil,
          updated_at: DateTime.t(),
          thread_count: non_neg_integer(),
          open_thread_count: non_neg_integer(),
          last_activity_at: DateTime.t() | nil,
          has_new_patchset: boolean()
        }

  def roles, do: @roles
  def statuses, do: @statuses
  def default_limit, do: @default_limit
  def max_limit, do: @max_limit

  @doc """
  Checks and fills in list filters from string- or atom-keyed params.

  Returns `{:ok, filters}` or `{:error, errors}`, where `errors` maps each bad
  param to a short message. Empty strings count as "not set".
  """
  @spec normalize_filters(map()) :: {:ok, filters()} | {:error, %{atom() => String.t()}}
  def normalize_filters(params) when is_map(params) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    results = [
      role: one_of(params["role"], @roles, "all"),
      status: one_of(params["status"], @statuses, "all"),
      author: text(params["author"]),
      q: text(params["q"]),
      limit: integer(params["limit"], @default_limit, 1, @max_limit),
      offset: integer(params["offset"], 0, 0, nil)
    ]

    errors = for {key, {:error, message}} <- results, into: %{}, do: {key, message}

    if errors == %{} do
      {:ok, Map.new(results, fn {key, {:ok, value}} -> {key, value} end)}
    else
      {:error, errors}
    end
  end

  @doc """
  Like `normalize_filters/1`, but drops bad params and uses the default
  instead. The web index uses this so a hand-edited URL still renders.
  """
  @spec normalize_filters_lenient(map()) :: filters()
  def normalize_filters_lenient(params) when is_map(params) do
    params = Map.new(params, fn {k, v} -> {to_string(k), v} end)

    case normalize_filters(params) do
      {:ok, filters} -> filters
      {:error, errors} -> normalize_filters_lenient(Map.drop(params, Enum.map(errors, &key/1)))
    end
  end

  defp key({field, _message}), do: Atom.to_string(field)

  @doc """
  Lists reviews for `viewer` with `filters` (see `normalize_filters/1`).

  Returns `%{entries: [entry], limit: n, offset: n, next_offset: n | nil}`.
  A `nil` viewer gets an empty list.
  """
  @spec list(User.t() | Identity.t() | nil, filters() | map()) :: %{
          entries: [entry()],
          limit: pos_integer(),
          offset: non_neg_integer(),
          next_offset: non_neg_integer() | nil
        }
  def list(viewer, filters \\ %{})

  def list(nil, filters) do
    filters = normalize_filters_lenient(filters)
    %{entries: [], limit: filters.limit, offset: filters.offset, next_offset: nil}
  end

  def list(viewer, filters) do
    filters = ensure_filters(filters)
    identity_ids = viewer_identity_ids(viewer)

    rows =
      identity_ids
      |> base_query()
      |> filter_role(filters.role, identity_ids)
      |> filter_status(filters.status)
      |> filter_author(filters.author)
      |> filter_search(filters.q)
      |> order_by([r, ps: ps], desc: fragment("GREATEST(?, ?)", r.updated_at, ps.last_pushed_at))
      |> order_by([r], desc: r.id)
      |> limit(^(filters.limit + 1))
      |> offset(^filters.offset)
      |> Repo.all()

    {page, rest} = Enum.split(rows, filters.limit)

    %{
      entries: Enum.map(page, &to_entry/1),
      limit: filters.limit,
      offset: filters.offset,
      next_offset: if(rest == [], do: nil, else: filters.offset + filters.limit)
    }
  end

  defp ensure_filters(%{role: _, status: _, author: _, q: _, limit: _, offset: _} = filters),
    do: filters

  defp ensure_filters(params), do: normalize_filters_lenient(params)

  defp viewer_identity_ids(%Identity{id: id}), do: [id]

  defp viewer_identity_ids(%User{} = user) do
    {:ok, _human} = Accounts.ensure_human_identity(user)
    user |> Accounts.list_identities_for() |> Enum.map(& &1.id)
  end

  # --- Query --------------------------------------------------------------

  defp base_query(identity_ids) do
    from r in Review,
      as: :review,
      join: a in assoc(r, :author),
      as: :author,
      left_join: ps in subquery(patchset_stats()),
      as: :ps,
      on: ps.review_id == r.id,
      left_join: th in subquery(thread_stats()),
      as: :th,
      on: th.review_id == r.id,
      left_join: act in subquery(activity(identity_ids)),
      as: :act,
      on: act.review_id == r.id,
      where: r.author_id in ^identity_ids or not is_nil(act.last_activity_at),
      select: %{
        review: r,
        author: a,
        authored: r.author_id in ^identity_ids,
        patchset_count: coalesce(ps.patchset_count, 0),
        latest_patchset_number: ps.latest_patchset_number,
        last_pushed_at: ps.last_pushed_at,
        updated_at: fragment("GREATEST(?, ?)", r.updated_at, ps.last_pushed_at),
        thread_count: coalesce(th.thread_count, 0),
        open_thread_count: coalesce(th.open_thread_count, 0),
        last_activity_at: act.last_activity_at
      }
  end

  defp patchset_stats do
    from p in Patchset,
      group_by: p.review_id,
      select: %{
        review_id: p.review_id,
        patchset_count: count(p.id),
        latest_patchset_number: max(p.number),
        last_pushed_at: max(coalesce(p.pushed_at, p.inserted_at))
      }
  end

  # Only threads with at least one comment are published (see
  # `Reviews.Threads.list_published_threads/1`).
  defp thread_stats do
    from t in Thread,
      as: :thread,
      where: exists(from c in Comment, where: c.thread_id == parent_as(:thread).id),
      group_by: t.review_id,
      select: %{
        review_id: t.review_id,
        thread_count: count(t.id),
        open_thread_count: filter(count(t.id), t.status == "open")
      }
  end

  # The viewer's latest action per review: a comment, a section decision, or a
  # viewed hunk by any of `identity_ids`.
  defp activity(identity_ids) do
    comments =
      from c in Comment,
        join: t in Thread,
        on: t.id == c.thread_id,
        where: c.author_id in ^identity_ids,
        select: %{review_id: t.review_id, at: c.inserted_at}

    decisions =
      from d in PacketSectionDecision,
        where: d.author_id in ^identity_ids,
        select: %{review_id: d.review_id, at: d.updated_at}

    views =
      from v in PacketHunkView,
        where: v.author_id in ^identity_ids,
        select: %{review_id: v.review_id, at: v.updated_at}

    events = comments |> union_all(^decisions) |> union_all(^views)

    from e in subquery(events),
      group_by: e.review_id,
      select: %{review_id: e.review_id, last_activity_at: max(e.at)}
  end

  defp filter_role(query, "all", _identity_ids), do: query

  defp filter_role(query, "authored", identity_ids),
    do: where(query, [review: r], r.author_id in ^identity_ids)

  defp filter_role(query, "involved", identity_ids),
    do: where(query, [review: r], r.author_id not in ^identity_ids)

  defp filter_status(query, "all"), do: query

  defp filter_status(query, "open"), do: where(query, [th: th], th.open_thread_count > 0)

  defp filter_status(query, "updated") do
    where(
      query,
      [ps: ps, act: act],
      not is_nil(act.last_activity_at) and ps.last_pushed_at > act.last_activity_at
    )
  end

  defp filter_author(query, nil), do: query

  defp filter_author(query, handle) do
    handle = handle |> String.trim_leading("@") |> String.downcase()
    where(query, [author: a], fragment("lower(?)", a.handle) == ^handle)
  end

  defp filter_search(query, nil), do: query

  defp filter_search(query, q) do
    pattern = "%" <> escape_like(q) <> "%"
    where(query, [review: r], ilike(r.title, ^pattern) or ilike(r.slug, ^pattern))
  end

  defp escape_like(text), do: String.replace(text, ~r/([\\%_])/, "\\\\\\1")

  defp to_entry(row) do
    review = %{row.review | author: row.author}

    %{
      review: review,
      role: if(row.authored, do: "authored", else: "involved"),
      patchset_count: row.patchset_count,
      latest_patchset_number: row.latest_patchset_number,
      last_pushed_at: to_utc(row.last_pushed_at),
      updated_at: to_utc(row.updated_at) || review.updated_at,
      thread_count: row.thread_count,
      open_thread_count: row.open_thread_count,
      last_activity_at: to_utc(row.last_activity_at),
      has_new_patchset: new_patchset?(row)
    }
  end

  defp new_patchset?(%{last_activity_at: nil}), do: false
  defp new_patchset?(%{last_pushed_at: nil}), do: false

  defp new_patchset?(%{last_activity_at: activity, last_pushed_at: pushed}),
    do: compare(pushed, activity) == :gt

  defp compare(a, b), do: NaiveDateTime.compare(to_naive(a), to_naive(b))

  defp to_naive(%DateTime{} = dt), do: DateTime.to_naive(dt)
  defp to_naive(%NaiveDateTime{} = dt), do: dt

  defp to_utc(nil), do: nil
  defp to_utc(%DateTime{} = dt), do: DateTime.truncate(dt, :second)

  defp to_utc(%NaiveDateTime{} = dt),
    do: dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second)

  # --- Param parsing ------------------------------------------------------

  defp one_of(nil, _allowed, default), do: {:ok, default}
  defp one_of("", _allowed, default), do: {:ok, default}

  defp one_of(value, allowed, _default) when is_binary(value) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, "must be one of: #{Enum.join(allowed, ", ")}"}
  end

  defp one_of(_value, allowed, _default),
    do: {:error, "must be one of: #{Enum.join(allowed, ", ")}"}

  defp text(nil), do: {:ok, nil}

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      trimmed -> {:ok, String.slice(trimmed, 0, 200)}
    end
  end

  defp text(_value), do: {:error, "must be text"}

  defp integer(nil, default, _min, _max), do: {:ok, default}
  defp integer("", default, _min, _max), do: {:ok, default}

  defp integer(value, default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> integer(int, default, min, max)
      _ -> {:error, "must be a whole number"}
    end
  end

  defp integer(value, _default, min, _max) when is_integer(value) and value < min,
    do: {:error, "must be #{min} or more"}

  defp integer(value, _default, _min, max)
       when is_integer(value) and is_integer(max) and value > max,
       do: {:error, "must be #{max} or less"}

  defp integer(value, _default, _min, _max) when is_integer(value), do: {:ok, value}
  defp integer(_value, _default, _min, _max), do: {:error, "must be a whole number"}
end
