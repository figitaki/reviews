defmodule ReviewsWeb.Api.ReviewerController do
  @moduledoc """
  Named reviewers of a review (`Reviews.Reviewers`). Anyone with the link may
  list them; only the owner may add or remove them. Every response is the
  updated list.
  """
  use ReviewsWeb, :controller

  alias Reviews.Reviewers
  alias Reviews.Reviews, as: ReviewsContext

  def index(conn, %{"slug" => slug}) do
    with {:ok, review} <- fetch_review(slug) do
      render_list(conn, review, Reviewers.list(review))
    else
      {:error, reason} -> ReviewsWeb.ApiErrors.render(conn, reason)
    end
  end

  # Idempotent: adding a reviewer twice returns the same list.
  def update(conn, %{"slug" => slug, "login" => login}) do
    write(conn, slug, &Reviewers.add(&1, conn.assigns.current_principal, login))
  end

  def delete(conn, %{"slug" => slug, "login" => login}) do
    write(conn, slug, &Reviewers.remove(&1, conn.assigns.current_principal, login))
  end

  defp write(conn, slug, fun) do
    with {:ok, review} <- fetch_review(slug),
         {:ok, reviewers} <- fun.(review) do
      render_list(conn, review, reviewers)
    else
      {:error, :forbidden} ->
        ReviewsWeb.ApiErrors.render(
          conn,
          :forbidden,
          "Only the review owner can add or remove reviewers"
        )

      {:error, reason} ->
        ReviewsWeb.ApiErrors.render(conn, reason)
    end
  end

  defp render_list(conn, review, reviewers) do
    json(conn, %{review: review.slug, reviewers: Enum.map(reviewers, &reviewer/1)})
  end

  @doc false
  def reviewer(reviewer) do
    %{
      login: reviewer.login,
      github_id: reviewer.github_id,
      status: reviewer.status,
      identity: ReviewsWeb.Payloads.identity(reviewer.identity),
      added_at: reviewer.added_at
    }
  end

  defp fetch_review(slug) do
    case ReviewsContext.get_review_by_slug(slug) do
      nil -> {:error, ReviewsContext.not_found_reason(slug)}
      review -> {:ok, review}
    end
  end
end
