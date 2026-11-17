defmodule Reviews.Policy do
  @moduledoc """
  Who may act on a review. Every surface (web, REST, CLI, Poppy, MCP) gets these
  rules from the context functions that call this module, so adapters only
  turn `{:error, :forbidden}` into their own error format.

    * Read: anyone with the review link, signed in or not.
    * Comment: any signed-in identity with the review link. A delegated
      principal also needs the `comments:write` scope.
    * Push a patchset: the review owner.
    * Resolve or reopen a thread: the review owner or the thread's author.
    * Decide a packet section: the review owner.

  "Owner" and "author" mean the account, not one identity: an account's human
  identity and its agent identities share its permissions.

  The actor is a `Reviews.Principal`, or a bare `Identity` (treated as a
  principal with every scope), or nil for a signed-out reader.
  """
  alias Reviews.Accounts.Identity
  alias Reviews.Principal
  alias Reviews.Repo
  alias Reviews.Reviews.Review

  @type action ::
          :read
          | :comment
          | :push
          | :decide_section
          | {:update_thread_status, thread :: map()}

  # The scope a delegated principal needs for each write. API tokens and web
  # sessions hold every scope.
  @scopes %{comment: "comments:write"}

  @spec can?(Principal.t() | Identity.t() | nil, action(), Review.t()) :: boolean()
  def can?(_actor, :read, %Review{}), do: true

  def can?(actor, action, %Review{} = review) do
    case Principal.from(actor) do
      %Principal{} = principal ->
        scoped?(principal, action) and allowed?(principal, action, review)

      nil ->
        false
    end
  end

  def can?(_actor, _action, _review), do: false

  defp scoped?(principal, action) do
    case Map.fetch(@scopes, action) do
      {:ok, scope} -> Principal.scope?(principal, scope)
      # Writes without a scope of their own are not delegated to OAuth clients.
      :error -> principal.scopes == :all
    end
  end

  defp allowed?(_principal, :comment, _review), do: true
  defp allowed?(%{identity: actor}, :push, review), do: owner?(actor, review)

  # Explicitly added reviewers will also be allowed here once that feature exists.
  defp allowed?(%{identity: actor}, :decide_section, review), do: owner?(actor, review)

  defp allowed?(%{identity: actor}, {:update_thread_status, thread}, review) do
    owner?(actor, review) or same_account?(actor, author(thread))
  end

  defp allowed?(_principal, _action, _review), do: false

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
