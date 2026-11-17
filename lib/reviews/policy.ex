defmodule Reviews.Policy do
  @moduledoc """
  Who may act on a review. Every surface (web, REST, CLI, Poppy, MCP) gets these
  rules from the context functions that call this module, so adapters only
  turn `{:error, :forbidden}` into their own error format.

    * Comment: any signed-in identity with the review link. Context functions
      require an identity, so there is no separate check.
    * Push a patchset: the review owner.
    * Resolve or reopen a thread: the review owner or the thread's author.
    * Decide a packet section: the review owner.

  "Owner" and "author" mean the account, not one identity: an account's human
  identity and its agent identities share its permissions.

  MCP still limits every tool to reviews the account owns, which is stricter
  than these rules, until it moves to them (#176, plan step 1).
  """
  alias Reviews.Accounts.Identity
  alias Reviews.Repo
  alias Reviews.Reviews.Review

  @type action :: :push | :decide_section | {:update_thread_status, thread :: map()}

  @spec can?(Identity.t() | nil, action(), Review.t()) :: boolean()
  def can?(%Identity{} = actor, :push, %Review{} = review), do: owner?(actor, review)

  # Explicitly added reviewers will also be allowed here once that feature exists.
  def can?(%Identity{} = actor, :decide_section, %Review{} = review), do: owner?(actor, review)

  def can?(%Identity{} = actor, {:update_thread_status, thread}, %Review{} = review) do
    owner?(actor, review) or same_account?(actor, author(thread))
  end

  def can?(_actor, _action, _review), do: false

  # Uses the preloaded author when there is one, so checking every thread of a
  # review does not cost a query each; otherwise asks `owned_by?/2`.
  defp owner?(actor, %Review{author: %Identity{} = author}), do: same_account?(actor, author)
  defp owner?(actor, review), do: Reviews.Reviews.owned_by?(review, actor)

  defp same_account?(%Identity{owner_user_id: id}, %Identity{owner_user_id: id})
       when not is_nil(id),
       do: true

  defp same_account?(_actor, _author), do: false

  # Threads carry `author_id`; listed threads have their author preloaded.
  defp author(%{author: %Identity{} = author}), do: author
  defp author(%{author_id: id}) when is_integer(id), do: Repo.get(Identity, id)
  defp author(_record), do: nil
end
