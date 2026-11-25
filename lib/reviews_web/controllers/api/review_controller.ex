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
        viewer = Reviews.Policy.list_viewer(conn.assigns.current_principal)
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

  defp render_list_entry(entry) do
    review = entry.review

    %{
      slug: review.slug,
      title: review.title,
      url: url(~p"/r/#{review.slug}"),
      author: ReviewsWeb.Payloads.identity(review.author),
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
        ReviewsWeb.ApiErrors.render(conn, ReviewsContext.not_found_reason(slug))

      {:error, :patchset_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(ReviewsWeb.ApiErrors.detail(:patchset_not_found, "Patchset not found"))
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
      code_snapshot_status: code_snapshot_status(ps),
      stats: ReviewNavigation.patchset_stats(ps)
    }
  end

  # Availability only — this endpoint is unauthenticated, so never expose
  # storage keys, refs, or provider identifiers.
  defp code_snapshot_status(ps) do
    case Map.get(ps, :code_snapshot) do
      %{status: status} -> status
      _ -> nil
    end
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
      generated: file.generated,
      vendored: file.vendored,
      raw_diff: file.raw_diff
    }
  end

  defp render_thread(thread) do
    ReviewsWeb.Payloads.thread(thread)
    |> Map.put(:comments, Enum.map(thread.comments || [], &ReviewsWeb.Payloads.comment/1))
  end

  @doc "POST /api/v1/reviews"
  def create(conn, params) do
    author = conn.assigns.current_identity

    with %{} = attrs <- normalize_params(params),
         {:ok, %{review: review, patchset: patchset} = result} <-
           ReviewsContext.create_review_with_initial_patchset(author, attrs) do
      response = %{
        id: review.id,
        slug: review.slug,
        url: url(~p"/r/#{review.slug}"),
        patchset_number: patchset.number
      }

      conn
      |> put_status(:created)
      |> json(maybe_put_code_snapshot(response, result[:code_snapshot]))
    else
      {:error, :code_snapshot, code, _} when is_atom(code) ->
        ReviewsWeb.ApiErrors.render(conn, code)

      {:error, _step, %Ecto.Changeset{} = changeset, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ReviewsWeb.ApiErrors.changeset(changeset))

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(ReviewsWeb.ApiErrors.changeset(changeset))

      _ ->
        conn
        |> put_status(:bad_request)
        |> json(ReviewsWeb.ApiErrors.detail(:invalid_request, "Invalid request"))
    end
  end

  @doc """
  GET /api/v1/reviews/:slug/deletion

  What deleting the review would remove, so a client can warn before it
  deletes. Owner only, like the deletion itself.
  """
  def deletion(conn, %{"slug" => slug}) do
    with {:ok, review} <- fetch_review(conn, slug) do
      if Reviews.Policy.can?(conn.assigns.current_principal, :delete, review) do
        summary = ReviewsContext.deletion_summary(review)
        json(conn, Map.merge(%{slug: review.slug, title: review.title}, summary))
      else
        forbidden(conn)
      end
    end
  end

  @doc "DELETE /api/v1/reviews/:slug"
  def delete(conn, %{"slug" => slug}) do
    with {:ok, review} <- fetch_review(conn, slug) do
      case ReviewsContext.delete_review(review, conn.assigns.current_principal) do
        {:ok, review} -> json(conn, %{slug: review.slug, deleted: true})
        {:error, :forbidden} -> forbidden(conn)
        {:error, reason} -> ReviewsWeb.ApiErrors.render(conn, reason)
      end
    end
  end

  # A deleted review's slug gets 410 `review_deleted`, an unknown one 404.
  defp fetch_review(conn, slug) do
    case ReviewsContext.get_review_by_slug(slug) do
      nil -> ReviewsWeb.ApiErrors.render(conn, ReviewsContext.not_found_reason(slug))
      review -> {:ok, review}
    end
  end

  defp forbidden(conn),
    do: ReviewsWeb.ApiErrors.render(conn, :forbidden, "Only the review owner can delete it.")

  defp normalize_params(params) when is_map(params) do
    %{
      title: params["title"],
      description: params["description"],
      base_sha: params["base_sha"],
      branch_name: params["branch_name"],
      raw_diff: params["raw_diff"],
      packet: params["packet"],
      code_snapshot_id: params["code_snapshot_id"],
      file_attributes: params["file_attributes"]
    }
  end

  defp normalize_params(_), do: nil

  # Absent when the push carried no snapshot id; "claimed" or "skipped"+code
  # otherwise so the CLI can warn without a second request.
  defp maybe_put_code_snapshot(response, nil), do: response

  defp maybe_put_code_snapshot(response, {:skipped, code}) do
    Map.put(response, :code_snapshot, %{status: "skipped", code: Atom.to_string(code)})
  end

  defp maybe_put_code_snapshot(response, snapshot) do
    Map.put(response, :code_snapshot, %{id: snapshot.public_id, status: snapshot.status})
  end
end
