defmodule Reviews.ReviewViewTest do
  use Reviews.DataCase, async: true

  alias Reviews.Accounts
  alias Reviews.ReviewView
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads

  defp user!(suffix) do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: "carey-#{suffix}",
        email: "carey-#{suffix}@example.com",
        avatar_url: nil
      })

    user
  end

  defp review_with_patchsets!(author) do
    diff_v1 =
      "diff --git a/foo b/foo\n" <>
        "--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"

    {:ok, %{review: review, patchset: ps1}} =
      ReviewsContext.create_review_with_initial_patchset(author, %{
        title: "Add foo",
        description: "Test review",
        base_sha: "deadbeef",
        branch_name: "carey/foo",
        raw_diff: diff_v1
      })

    diff_v2 =
      "diff --git a/foo b/foo\n" <>
        "--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+newer\n"

    {:ok, ps2} =
      ReviewsContext.append_patchset(review, %{
        base_sha: "cafef00d",
        branch_name: "carey/foo",
        raw_diff: diff_v2
      })

    %{review: review, ps1: ps1, ps2: ps2}
  end

  defp comment_params(body) do
    %{
      "file_path" => "foo",
      "side" => "new",
      "body" => body,
      "thread_anchor" => %{
        "granularity" => "line",
        "line_text" => "newer",
        "context_before" => [],
        "context_after" => [],
        "line_number_hint" => 1
      }
    }
  end

  test "defaults to the latest patchset and builds file payloads" do
    author = user!("author")
    %{review: review, ps2: ps2} = review_with_patchsets!(author)

    assert {:ok, snapshot} = ReviewView.get_snapshot_by_slug(review.slug, nil)

    assert snapshot.review.id == review.id
    assert snapshot.selected_patchset.id == ps2.id
    assert length(snapshot.patchsets) == 2

    assert [%{path: "foo", additions: 1, deletions: 1, raw_diff: raw_diff}] =
             snapshot.file_diffs

    assert raw_diff =~ "+newer"
  end

  test "supports explicit patchset selection" do
    author = user!("author")
    %{review: review, ps1: ps1} = review_with_patchsets!(author)

    assert {:ok, snapshot} =
             ReviewView.get_snapshot_by_slug(review.slug, nil, patchset_number: ps1.number)

    assert snapshot.selected_patchset.id == ps1.id
    assert [%{raw_diff: raw_diff}] = snapshot.file_diffs
    assert raw_diff =~ "+new\n"
    refute raw_diff =~ "newer"
  end

  test "includes comments as shared published threads immediately" do
    author = user!("author")
    other = user!("other")
    %{review: review} = review_with_patchsets!(author)

    {:ok, _} = Threads.publish_comment(review, author, comment_params("visible comment"))

    assert {:ok, anonymous_snapshot} = ReviewView.get_snapshot_by_slug(review.slug, nil)
    assert [anonymous_thread] = anonymous_snapshot.published_threads
    assert [%{body: "visible comment"}] = anonymous_thread.comments

    assert {:ok, other_snapshot} = ReviewView.get_snapshot_by_slug(review.slug, other)
    assert [thread] = other_snapshot.published_threads
    assert [%{body: "visible comment"}] = thread.comments
  end

  test "returns explicit errors for missing reviews and patchsets" do
    author = user!("author")
    %{review: review} = review_with_patchsets!(author)

    assert {:error, :not_found} = ReviewView.get_snapshot_by_slug("missing", nil)

    assert {:error, :patchset_not_found} =
             ReviewView.get_snapshot_by_slug(review.slug, nil, patchset_number: 99)
  end
end
