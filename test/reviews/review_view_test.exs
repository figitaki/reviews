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

  test "includes one published decider per reviewer, without the review author" do
    author = user!("author")
    first = user!("first")
    other = user!("other")
    %{review: review} = review_with_patchsets!(author)

    {:ok, _} = Threads.publish_comment(review, author, comment_params("author note"))
    {:ok, _} = Threads.publish_comment(review, first, comment_params("first"))
    {:ok, _} = Threads.publish_comment(review, first, comment_params("second"))
    {:ok, _} = Threads.publish_comment(review, other, comment_params("third"))

    assert {:ok, snapshot} = ReviewView.get_snapshot_by_slug(review.slug, nil)

    assert [
             %{author: %{handle: "carey-first"}, decision: "commented", comment_count: 2},
             %{author: %{handle: "carey-other"}, decision: "commented", comment_count: 1}
           ] = snapshot.deciders
  end

  test "returns explicit errors for missing reviews and patchsets" do
    author = user!("author")
    %{review: review} = review_with_patchsets!(author)

    assert {:error, :not_found} = ReviewView.get_snapshot_by_slug("missing", nil)

    assert {:error, :patchset_not_found} =
             ReviewView.get_snapshot_by_slug(review.slug, nil, patchset_number: 99)
  end

  test "projects moved resolved threads without rewriting origin or resolution history" do
    author = user!("projection")
    %{review: review, ps1: ps1, ps2: ps2} = review_with_patchsets!(author)
    params = comment_params("original")

    params =
      params
      |> Map.put("originating_patchset_id", ps1.id)
      |> put_in(["thread_anchor", "line_text"], "new")

    {:ok, %{thread: original}} = Threads.publish_comment(review, author, params)
    {:ok, resolved} = Threads.update_status(review, original.id, author, "resolved")

    {:ok, ps3} =
      ReviewsContext.append_patchset(review, %{
        raw_diff:
          "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -8 +8,2 @@\n-old\n+inserted\n+new\n"
      })

    assert {:ok, latest} = ReviewView.snapshot(review, nil)
    assert [projected] = latest.published_threads
    assert projected.anchor["line_number_hint"] == 9
    assert projected.anchor_status == "current"
    assert projected.original_anchor == original.anchor
    assert projected.originating_patchset_id == ps1.id
    assert projected.originating_patchset_number == 1
    assert projected.status == "resolved"
    assert projected.resolved_at == resolved.resolved_at
    assert projected.resolved_by_id == resolved.resolved_by_id

    assert [%{anchor: %{"line_number_hint" => 9}}] =
             ReviewView.thread_payloads_for_file(latest, "foo")

    assert {:ok, vanished} = ReviewView.snapshot(review, nil, patchset_number: ps2.number)

    assert [%{anchor_status: "outdated", anchor: nil, status: "resolved"}] =
             vanished.published_threads

    assert [] == ReviewView.thread_payloads_for_file(vanished, "foo")

    assert {:ok, earlier} = ReviewView.snapshot(review, nil, patchset_number: ps1.number)
    assert [historic] = earlier.published_threads
    assert historic.anchor == original.anchor
    assert historic.anchor_status == "current"

    assert {:ok, %{thread: replied}} =
             Threads.publish_comment(
               review,
               author,
               params
               |> Map.put("body", "reply on latest")
               |> Map.put("thread_id", original.id)
               |> Map.put("originating_patchset_id", ps3.id)
             )

    assert replied.originating_patchset_id == ps1.id
    assert replied.anchor == original.anchor

    assert [%{anchor: stored_anchor, originating_patchset_id: origin_id}] =
             Threads.list_published_threads(review.id)

    assert stored_anchor == original.anchor
    assert origin_id == ps1.id
    assert latest.selected_patchset.id == ps3.id
  end

  test "future-origin threads are absent on earlier revisions" do
    author = user!("future")
    %{review: review, ps1: ps1} = review_with_patchsets!(author)
    {:ok, _} = Threads.publish_comment(review, author, comment_params("future"))
    assert {:ok, earlier} = ReviewView.snapshot(review, nil, patchset_number: ps1.number)
    assert earlier.published_threads == []
    assert ReviewView.thread_payloads_for_file(earlier, "foo") == []
  end

  test "token threads move while duplicates and missing code remain only in activity" do
    author = user!("tokens")
    %{review: review, ps1: ps1} = review_with_patchsets!(author)
    params = comment_params("selected") |> Map.put("originating_patchset_id", ps1.id)

    params =
      put_in(params["thread_anchor"], %{
        "granularity" => "token_range",
        "line_number_hint" => 1,
        "line_text" => "new",
        "selection_text" => "new",
        "selection_offset" => 0
      })

    {:ok, _} = Threads.publish_comment(review, author, params)

    for {body, expected} <- [
          {"+new", "current"},
          {"+new\n+new", "outdated"},
          {"+gone", "outdated"}
        ] do
      {:ok, _} =
        ReviewsContext.append_patchset(review, %{
          raw_diff: "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -20 +20 @@\n-old\n#{body}\n"
        })

      assert {:ok, snapshot} = ReviewView.snapshot(review, nil)
      assert [projected] = snapshot.published_threads
      assert projected.anchor_status == expected

      if expected == "current" do
        assert [
                 %{
                   anchor: %{
                     "line_number_hint" => 20,
                     "selection_text" => "new",
                     "selection_offset" => 0
                   }
                 }
               ] = ReviewView.thread_payloads_for_file(snapshot, "foo")
      else
        assert ReviewView.thread_payloads_for_file(snapshot, "foo") == []
      end
    end
  end

  test "explicit comment origins reject patchsets from other reviews and invalid ids" do
    author = user!("origin-validation")
    %{review: review} = review_with_patchsets!(author)
    %{ps1: foreign} = review_with_patchsets!(author)

    for id <- [foreign.id, "invalid", -1, false] do
      assert {:error, :patchset_not_found} =
               Threads.publish_comment(
                 review,
                 author,
                 Map.put(comment_params("bad"), "originating_patchset_id", id)
               )
    end

    assert Threads.list_published_threads(review.id) == []
  end
end
