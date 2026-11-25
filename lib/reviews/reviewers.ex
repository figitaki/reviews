defmodule Reviews.Reviewers do
  @moduledoc """
  Named reviewers of a review (#214, `docs/design/named-reviewers.md`).

  The review owner adds reviewers by GitHub login. The login is looked up
  with GitHub's public API (`Reviews.GitHubUsers`) and the reviewer is stored
  and matched by GitHub's numeric user ID, never by login text, so a renamed
  or reused login cannot take over someone's place. A reviewer who has not
  signed up yet is `"invited"`; once an account with that GitHub ID exists,
  the reviewer is `"active"` and may decide sections (`Reviews.Policy`), with
  any of the account's agent identities deciding on its behalf.

  Only the owner may add or remove reviewers (`:manage_reviewers`). Anyone
  with the review link may list them. Removing a reviewer keeps their
  decisions; they stop counting until the reviewer is added again.

  Every change broadcasts `:reviewers_changed` on `"review:<slug>"`.
  """
  import Ecto.Query, warn: false

  alias Reviews.Accounts.{Identity, User}
  alias Reviews.GitHubUsers
  alias Reviews.Policy
  alias Reviews.Repo
  alias Reviews.Reviews.{Review, ReviewReviewer}

  @type reviewer :: %{
          github_id: integer(),
          login: String.t(),
          status: String.t(),
          identity: Identity.t() | nil,
          added_at: DateTime.t()
        }

  @doc """
  The review's reviewers in the order they were added. `login` is the
  account's current GitHub login once it has signed up, else the login GitHub
  returned when the reviewer was added. `identity` is the account's human
  identity, or nil while the reviewer is invited.
  """
  @spec list(Review.t()) :: [reviewer()]
  def list(%Review{id: review_id}) do
    from(r in ReviewReviewer,
      left_join: u in User,
      on: u.github_id == r.github_id,
      left_join: i in Identity,
      on: i.owner_user_id == u.id and i.kind == "human",
      where: r.review_id == ^review_id,
      order_by: [asc: r.inserted_at, asc: r.id],
      select: %{
        github_id: r.github_id,
        login: coalesce(u.username, r.github_login),
        status: fragment("CASE WHEN ? IS NULL THEN 'invited' ELSE 'active' END", u.id),
        identity: i,
        added_at: r.inserted_at
      }
    )
    |> Repo.all()
  end

  @doc "True when `identity`'s account is a named reviewer of `review`."
  @spec reviewer?(Review.t(), Identity.t()) :: boolean()
  def reviewer?(%Review{id: review_id}, %Identity{owner_user_id: account_id})
      when not is_nil(account_id) do
    Repo.exists?(
      from r in ReviewReviewer,
        join: u in User,
        on: u.github_id == r.github_id,
        where: r.review_id == ^review_id and u.id == ^account_id
    )
  end

  def reviewer?(_review, _identity), do: false

  @doc """
  Adds the GitHub account `login` as a reviewer. Adding a reviewer twice
  changes nothing. Returns `{:ok, reviewers}` with the updated list, or
  `{:error, reason}`: `:forbidden`, `:github_user_not_found`,
  `:github_unavailable`, or `:reviewer_is_owner`.
  """
  def add(%Review{} = review, actor, login) do
    with :ok <- authorize(actor, review),
         {:ok, %{github_id: github_id, login: login}} <- lookup(login),
         :ok <- not_owner(review, github_id) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %ReviewReviewer{}
      |> ReviewReviewer.changeset(%{
        review_id: review.id,
        github_id: github_id,
        github_login: login,
        added_by_id: added_by_id(actor)
      })
      |> Repo.insert!(
        on_conflict: [set: [github_login: login, updated_at: now]],
        conflict_target: [:review_id, :github_id]
      )

      changed(review)
    end
  end

  @doc """
  Removes the reviewer shown as `login` in `list/1` (case-insensitive).
  Removing someone who is not a reviewer changes nothing. Their decisions
  stay. Returns `{:ok, reviewers}` or `{:error, :forbidden}`.
  """
  def remove(%Review{} = review, actor, login) when is_binary(login) do
    with :ok <- authorize(actor, review) do
      login = login |> String.trim() |> String.trim_leading("@") |> String.downcase()

      ids =
        for reviewer <- list(review),
            String.downcase(reviewer.login) == login,
            do: reviewer.github_id

      {count, _} =
        Repo.delete_all(
          from r in ReviewReviewer, where: r.review_id == ^review.id and r.github_id in ^ids
        )

      if count > 0, do: changed(review), else: {:ok, list(review)}
    end
  end

  defp authorize(actor, review) do
    if Policy.can?(actor, :manage_reviewers, review), do: :ok, else: {:error, :forbidden}
  end

  defp not_owner(%Review{author_id: author_id}, github_id) do
    owner =
      Repo.exists?(
        from i in Identity,
          join: u in User,
          on: u.id == i.owner_user_id,
          where: i.id == ^author_id and u.github_id == ^github_id
      )

    if owner, do: {:error, :reviewer_is_owner}, else: :ok
  end

  defp lookup(login) do
    case GitHubUsers.lookup(login) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> {:error, :github_user_not_found}
      {:error, :unavailable} -> {:error, :github_unavailable}
    end
  end

  defp added_by_id(actor) do
    case Reviews.Principal.from(actor) do
      %{identity: %Identity{id: id}} -> id
      _ -> nil
    end
  end

  defp changed(review) do
    Phoenix.PubSub.broadcast(Reviews.PubSub, "review:#{review.slug}", :reviewers_changed)
    {:ok, list(review)}
  end
end
