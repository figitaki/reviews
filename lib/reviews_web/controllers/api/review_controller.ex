defmodule ReviewsWeb.Api.ReviewController do
  @moduledoc """
  CLI-facing `/api/v1/reviews` endpoint.

  `POST` creates a new review along with patchset #1 and returns the URL the
  user should open. Bearer-token auth via `Plugs.RequireApiToken` (mounted
  in the router pipeline).

  `GET /api/v1/reviews` lists the reviews the token's actor wrote or took
  part in (see `Reviews.ReviewIndex`). Bearer-token auth. A human-identity
  token lists reviews for all of the owner's identities. An agent-identity
  token lists only that agent's reviews.

  `GET /api/v1/reviews/:slug` is the read counterpart — public (matches the
  anonymous web view) and returns a JSON snapshot intended for agents
  consuming reviews from the CLI.
  """
  use ReviewsWeb, :controller

  alias Reviews.{ReviewIndex, ReviewNavigation, ReviewPacket, ReviewView}
  alias Reviews.Reviews, as: ReviewsContext

  @doc "GET /api/v1/reviews"
  def index(conn, params) do
    case ReviewIndex.normalize_filters(params) do
      {:ok, filters} ->
        viewer = list_viewer(conn.assigns.current_user, conn.assigns.current_identity)
        result = ReviewsContext.list_reviews(viewer, filters)

        json(conn, %{
          reviews: Enum.map(result.entries, &render_list_entry/1),
          limit: result.limit,
          offset: result.offset,
          next_offset: result.next_offset
        })

      {:error, errors} ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: errors})
    end
  end

  defp list_viewer(user, %{kind: "human"}), do: user
  defp list_viewer(_user, identity), do: identity

  defp render_list_entry(entry) do
    review = entry.review

    %{
      slug: review.slug,
      title: review.title,
      url: url(~p"/r/#{review.slug}"),
      author: render_identity(review.author),
      role: entry.role,
      patchset_count: entry.patchset_count,
      latest_patchset_number: entry.latest_patchset_number,
      last_pushed_at: entry.last_pushed_at,
      updated_at: entry.updated_at,
      thread_count: entry.thread_count,
      open_thread_count: entry.open_thread_count,
      last_activity_at: entry.last_activity_at,
      has_new_patchset: entry.has_new_patchset,
      created_at: review.inserted_at
    }
  end

  @doc "GET /api/v1/reviews/:slug"
  def show(conn, %{"slug" => slug} = params) do
    with {:ok, patchset_number} <- parse_patchset_number(params["patchset"]),
         {:ok, snapshot} <-
           ReviewView.get_snapshot_by_slug(slug, nil, patchset_number: patchset_number) do
      json(conn, render_review(snapshot))
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "Review not found"}})

      {:error, :patchset_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "Patchset not found"}})
    end
  end

  defp parse_patchset_number(nil), do: {:ok, nil}

  defp parse_patchset_number(n) when is_binary(n) do
    case Integer.parse(n) do
      {num, ""} -> {:ok, num}
      _ -> {:error, :patchset_not_found}
    end
  end

  defp render_review(snapshot) do
    review = snapshot.review

    %{
      slug: review.slug,
      title: review.title,
      description: review.description,
      url: url(~p"/r/#{review.slug}"),
      patchsets: Enum.map(snapshot.patchsets, &render_patchset_meta/1),
      selected_patchset: snapshot.selected_patchset && render_patchset(snapshot),
      threads: Enum.map(snapshot.published_threads, &render_thread/1)
    }
  end

  defp render_patchset_meta(ps) do
    %{
      number: ps.number,
      base_sha: ps.base_sha,
      branch_name: ps.branch_name,
      pushed_at: ps.pushed_at,
      packet_present: ReviewPacket.present?(ps.packet),
      stats: ReviewNavigation.patchset_stats(ps)
    }
  end

  defp render_patchset(snapshot) do
    ps = snapshot.selected_patchset

    %{
      number: ps.number,
      base_sha: ps.base_sha,
      branch_name: ps.branch_name,
      pushed_at: ps.pushed_at,
      packet: ps.packet,
      stats: ReviewNavigation.patchset_stats(ps),
      files: Enum.map(ReviewView.file_payloads(snapshot), &render_file/1)
    }
  end

  defp render_file(file) do
    %{
      path: file.path,
      old_path: file.old_path,
      status: file.status,
      additions: file.additions,
      deletions: file.deletions,
      raw_diff: file.raw_diff
    }
  end

  defp render_thread(thread) do
    %{
      file_path: thread.file_path,
      side: thread.side,
      line_hint: get_in(thread.anchor || %{}, ["line_number_hint"]),
      status: thread.status,
      author: render_identity(thread.author),
      comments:
        Enum.map(thread.comments || [], fn c ->
          %{
            body: c.body,
            author: render_identity(c.author),
            inserted_at: c.inserted_at
          }
        end)
    }
  end

  defp render_identity(nil), do: nil

  defp render_identity(identity) do
    %{
      id: identity.id,
      kind: identity.kind,
      handle: identity.handle,
      username: identity.handle,
      display_name: identity.display_name,
      avatar_url: identity.avatar_url
    }
  end

  @doc "POST /api/v1/reviews"
  def create(conn, params) do
    author = conn.assigns.current_identity

    with %{} = attrs <- normalize_params(params),
         {:ok, %{review: review, patchset: patchset}} <-
           ReviewsContext.create_review_with_initial_patchset(author, attrs) do
      conn
      |> put_status(:created)
      |> json(%{
        id: review.id,
        slug: review.slug,
        url: url(~p"/r/#{review.slug}"),
        patchset_number: patchset.number
      })
    else
      {:error, _step, changeset, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_changeset(changeset)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_changeset(changeset)})

      _ ->
        conn |> put_status(:bad_request) |> json(%{errors: %{detail: "Invalid request"}})
    end
  end

  defp normalize_params(params) when is_map(params) do
    %{
      title: params["title"],
      description: params["description"],
      base_sha: params["base_sha"],
      branch_name: params["branch_name"],
      raw_diff: params["raw_diff"],
      packet: params["packet"]
    }
  end

  defp normalize_params(_), do: nil

  defp format_changeset(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
