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

  defp draft_params(body) do
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
    assert snapshot.drafts == []

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

  test "includes only the signed-in viewer's drafts while published threads are shared" do
    author = user!("author")
    other = user!("other")
    %{review: review} = review_with_patchsets!(author)

    {:ok, _} = Threads.save_draft(review, author, draft_params("private draft"))

    assert {:ok, anonymous_snapshot} = ReviewView.get_snapshot_by_slug(review.slug, nil)
    assert anonymous_snapshot.drafts == []
    assert anonymous_snapshot.published_threads == []

    assert {:ok, other_snapshot} = ReviewView.get_snapshot_by_slug(review.slug, other)
    assert other_snapshot.drafts == []

    assert {:ok, author_snapshot} = ReviewView.get_snapshot_by_slug(review.slug, author)
    assert [%{comment: %{body: "private draft"}}] = author_snapshot.drafts

    {:ok, _} = Threads.publish_all_drafts(review, author)

    assert {:ok, published_snapshot} = ReviewView.get_snapshot_by_slug(review.slug, other)
    assert published_snapshot.drafts == []
    assert [thread] = published_snapshot.published_threads
    assert [%{body: "private draft"}] = thread.comments
  end

  test "returns explicit errors for missing reviews and patchsets" do
    author = user!("author")
    %{review: review} = review_with_patchsets!(author)

    assert {:error, :not_found} = ReviewView.get_snapshot_by_slug("missing", nil)

    assert {:error, :patchset_not_found} =
             ReviewView.get_snapshot_by_slug(review.slug, nil, patchset_number: 99)
  end
end
