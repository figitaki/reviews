defmodule Reviews.ReviewIndexFixtures do
  @moduledoc """
  Test helpers for the review index: users, reviews, comments, and fixed
  timestamps.
  """
  import Ecto.Query

  alias Reviews.Accounts
  alias Reviews.Repo
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.{Patchset, Review}
  alias Reviews.Threads

  @raw_diff """
  diff --git a/lib/foo.ex b/lib/foo.ex
  --- a/lib/foo.ex
  +++ b/lib/foo.ex
  @@ -1,3 +1,3 @@
   defmodule Foo do
  -  def bar, do: :old
  +  def bar, do: :new
   end
  """

  def raw_diff, do: @raw_diff

  def user!(username) do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: username,
        email: "#{username}@example.com",
        avatar_url: nil
      })

    user
  end

  def human!(user) do
    {:ok, identity} = Accounts.ensure_human_identity(user)
    identity
  end

  def agent!(user, handle) do
    {:ok, agent} =
      Accounts.create_agent_identity(user, %{
        display_name: String.capitalize(handle),
        handle: handle
      })

    agent
  end

  def review!(author, title, opts \\ []) do
    {:ok, %{review: review}} =
      ReviewsContext.create_review_with_initial_patchset(author, %{
        title: title,
        raw_diff: @raw_diff
      })

    if at = opts[:at], do: set_times!(review, at)
    Repo.get!(Review, review.id)
  end

  def patchset!(review, at) do
    {:ok, patchset} = ReviewsContext.append_patchset(review, %{raw_diff: @raw_diff})

    Repo.update_all(from(p in Patchset, where: p.id == ^patchset.id),
      set: [pushed_at: at, inserted_at: at]
    )

    patchset
  end

  def comment!(review, author, body \\ "Looks good.", opts \\ []) do
    {:ok, %{comment: comment}} =
      Threads.publish_comment(review, author, %{
        "file_path" => "lib/foo.ex",
        "side" => "new",
        "body" => body,
        "thread_anchor" => %{
          "granularity" => "line",
          "line_text" => "  def bar, do: :new",
          "context_before" => ["defmodule Foo do"],
          "context_after" => ["end"],
          "line_number_hint" => 2
        }
      })

    if at = opts[:at] do
      Repo.update_all(from(c in Reviews.Threads.Comment, where: c.id == ^comment.id),
        set: [inserted_at: at]
      )
    end

    comment
  end

  @doc "Sets the review and its patchsets to one fixed time."
  def set_times!(review, at) do
    Repo.update_all(from(r in Review, where: r.id == ^review.id),
      set: [inserted_at: at, updated_at: at]
    )

    Repo.update_all(from(p in Patchset, where: p.review_id == ^review.id),
      set: [pushed_at: at, inserted_at: at]
    )
  end

  def at(minutes_ago) do
    DateTime.utc_now()
    |> DateTime.add(-minutes_ago * 60, :second)
    |> DateTime.truncate(:second)
  end
end
