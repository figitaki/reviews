defmodule Reviews.Reviews.DeletionHook do
  @moduledoc """
  Lets other parts of the app clean up what they keep for a review when its
  owner deletes it.

  `Reviews.Reviews.delete_review/2` calls every module listed under
  `config :reviews, :review_deletion_hooks` inside the deletion transaction,
  after it locks the review row and before it deletes any rows. A hook that
  returns `{:error, reason}` rolls the whole deletion back.

  Hooks run before the database cascades, so they still see the review's
  rows. Work outside the database, such as deleting provider repositories,
  should not happen in the hook: the transaction can still roll back. Record
  the work instead (for example, mark rows for a sweeper to delete) so it
  commits or rolls back with the deletion and can be retried.
  """
  alias Reviews.Reviews.Review

  @callback before_review_delete(Review.t()) :: :ok | {:error, term()}

  @doc "Runs the configured hooks in order and stops at the first error."
  @spec run(Review.t()) :: :ok | {:error, term()}
  def run(%Review{} = review) do
    :reviews
    |> Application.get_env(:review_deletion_hooks, [])
    |> Enum.reduce_while(:ok, fn hook, :ok ->
      case hook.before_review_delete(review) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
