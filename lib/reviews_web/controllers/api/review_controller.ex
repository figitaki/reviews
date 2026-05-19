defmodule ReviewsWeb.Api.ReviewController do
  @moduledoc """
  CLI-facing `/api/v1/reviews` endpoint.

  `POST` creates a new review along with patchset #1 and returns the URL the
  user should open. Bearer-token auth via `Plugs.RequireApiToken` (mounted
  in the router pipeline).

  `GET /api/v1/reviews/:slug` is the read counterpart — public (matches the
  anonymous web view) and returns a JSON snapshot intended for agents
  consuming reviews from the CLI.
  """
  use ReviewsWeb, :controller

  alias Reviews.{ReviewNavigation, ReviewPacket, ReviewView}
  alias Reviews.Reviews, as: ReviewsContext

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
    author_username = thread.author && thread.author.username

    %{
      file_path: thread.file_path,
      side: thread.side,
      line_hint: get_in(thread.anchor || %{}, ["line_number_hint"]),
      status: thread.status,
      author: author_username,
      comments:
        Enum.map(thread.comments || [], fn c ->
          %{
            body: c.body,
            author: author_username,
            published_at: c.published_at
          }
        end)
    }
  end

  @doc "POST /api/v1/reviews"
  def create(conn, params) do
    author = conn.assigns.current_user

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
