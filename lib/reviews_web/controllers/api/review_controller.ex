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

  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads, as: ThreadsContext

  @doc "GET /api/v1/reviews/:slug"
  def show(conn, %{"slug" => slug} = params) do
    case ReviewsContext.get_review_by_slug(slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "Review not found"}})

      review ->
        patchsets = ReviewsContext.list_patchsets(review)
        selected = pick_patchset(patchsets, params["patchset"])

        cond do
          patchsets == [] ->
            conn |> put_status(:ok) |> json(render_review(review, [], nil, []))

          selected == nil ->
            conn
            |> put_status(:not_found)
            |> json(%{errors: %{detail: "Patchset not found"}})

          true ->
            threads = ThreadsContext.list_published_threads(review.id)
            json(conn, render_review(review, patchsets, selected, threads))
        end
    end
  end

  defp pick_patchset([], _), do: nil
  defp pick_patchset(patchsets, nil), do: List.last(patchsets)

  defp pick_patchset(patchsets, n) when is_binary(n) do
    case Integer.parse(n) do
      {num, ""} -> Enum.find(patchsets, &(&1.number == num))
      _ -> nil
    end
  end

  defp render_review(review, patchsets, selected, threads) do
    %{
      slug: review.slug,
      title: review.title,
      description: review.description,
      url: url(~p"/r/#{review.slug}"),
      patchsets: Enum.map(patchsets, &render_patchset_meta/1),
      selected_patchset: selected && render_patchset(selected),
      threads: Enum.map(threads, &render_thread/1)
    }
  end

  defp render_patchset_meta(ps) do
    %{
      number: ps.number,
      base_sha: ps.base_sha,
      branch_name: ps.branch_name,
      pushed_at: ps.pushed_at
    }
  end

  defp render_patchset(ps) do
    files = ReviewsContext.list_files(ps)
    parsed = ReviewsContext.parse_diff_files(ps.raw_diff || "") |> Enum.into(%{}, &{&1.path, &1})

    file_payload =
      Enum.map(files, fn file ->
        meta = Map.get(parsed, file.path, %{additions: 0, deletions: 0})

        %{
          path: file.path,
          old_path: file.old_path,
          status: file.status,
          additions: Map.get(meta, :additions, 0),
          deletions: Map.get(meta, :deletions, 0),
          raw_diff: ReviewsContext.raw_diff_for_file(ps, file.path) || ""
        }
      end)

    %{
      number: ps.number,
      base_sha: ps.base_sha,
      branch_name: ps.branch_name,
      pushed_at: ps.pushed_at,
      files: file_payload
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
      raw_diff: params["raw_diff"]
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
