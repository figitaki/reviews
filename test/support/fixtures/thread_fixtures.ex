defmodule Reviews.ThreadFixtures do
  @moduledoc false

  alias Reviews.Accounts
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads

  def thread_fixture do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 1_000_000 + unique,
        username: "thread-fixture-#{unique}",
        email: "thread-fixture@example.com"
      })

    {:ok, agent} =
      Accounts.create_agent_identity(user, %{handle: "codex", display_name: "Codex"})

    {:ok, %{review: review}} =
      ReviewsContext.create_review_with_initial_patchset(user, %{
        title: "Thread concurrency",
        raw_diff: "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"
      })

    {:ok, %{thread: thread}} =
      Threads.publish_comment(review, user, %{
        "file_path" => "foo",
        "side" => "new",
        "body" => "A comment",
        "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
      })

    %{
      user: user,
      identity: Accounts.human_identity_for(user),
      agent: agent,
      review: review,
      thread: thread
    }
  end
end
