defmodule Reviews.ThreadsTest do
  use Reviews.DataCase, async: true

  alias Reviews.Accounts
  alias Reviews.Reviews, as: ReviewsCtx
  alias Reviews.Threads
  alias Reviews.Threads.{Comment, Thread}

  defp setup_review!(extra \\ %{}) do
    {:ok, author} =
      Accounts.upsert_from_github(%{
        github_id: 1234 + System.unique_integer([:positive]),
        username: "carey-#{System.unique_integer([:positive])}",
        email: "carey@example.com",
        avatar_url: nil
      })

    raw_diff =
      Map.get(
        extra,
        :raw_diff,
        """
        diff --git a/lib/foo.ex b/lib/foo.ex
        --- a/lib/foo.ex
        +++ b/lib/foo.ex
        @@ -1,3 +1,3 @@
         defmodule Foo do
        -  def bar, do: :old
        +  def bar, do: :new
         end
        """
      )

    {:ok, %{review: review, patchset: _ps}} =
      ReviewsCtx.create_review_with_initial_patchset(author, %{
        title: "T",
        raw_diff: raw_diff
      })

    %{author: author, review: review}
  end

  describe "save_draft/3" do
    test "creates a thread + draft comment from a valid payload" do
      %{author: author, review: review} = setup_review!()

      params = %{
        "file_path" => "lib/foo.ex",
        "side" => "new",
        "body" => "Should be `:newer`?",
        "thread_anchor" => %{
          "granularity" => "line",
          "line_text" => "  def bar, do: :new",
          "context_before" => ["defmodule Foo do"],
          "context_after" => ["end"],
          "line_number_hint" => 2
        }
      }

      assert {:ok, %{thread: %Thread{} = thread, comment: %Comment{} = comment}} =
               Threads.save_draft(review, author, params)

      assert thread.file_path == "lib/foo.ex"
      assert thread.side == "new"
      assert thread.anchor["granularity"] == "line"
      assert comment.state == "draft"
      assert comment.body == "Should be `:newer`?"
      assert comment.author_id == author.id
    end

    test "saving twice with the same thread updates the existing draft (upsert)" do
      %{author: author, review: review} = setup_review!()

      base_params = %{
        "file_path" => "lib/foo.ex",
        "side" => "new",
        "thread_anchor" => %{
          "granularity" => "line",
          "line_text" => "  def bar, do: :new",
          "context_before" => [],
          "context_after" => [],
          "line_number_hint" => 2
        }
      }

      {:ok, %{thread: thread1, comment: comment1}} =
        Threads.save_draft(review, author, Map.put(base_params, "body", "first"))

      {:ok, %{thread: thread2, comment: comment2}} =
        Threads.save_draft(
          review,
          author,
          base_params
          |> Map.put("body", "edited")
          |> Map.put("thread_id", thread1.id)
        )

      assert thread1.id == thread2.id
      assert comment1.id == comment2.id
      assert comment2.body == "edited"
      assert comment2.state == "draft"

      # And the partial unique index keeps us at exactly one draft.
      drafts =
        Repo.all(
          from c in Comment,
            where: c.thread_id == ^thread1.id and c.author_id == ^author.id and c.state == "draft"
        )

      assert length(drafts) == 1
    end

    test "rejects empty body" do
      %{author: author, review: review} = setup_review!()

      params = %{
        "file_path" => "lib/foo.ex",
        "side" => "new",
        "body" => "   ",
        "thread_anchor" => %{"granularity" => "line"}
      }

      assert {:error, :empty_body} = Threads.save_draft(review, author, params)
    end

    test "rejects invalid side" do
      %{author: author, review: review} = setup_review!()

      params = %{
        "file_path" => "lib/foo.ex",
        "side" => "middle",
        "body" => "hi",
        "thread_anchor" => %{"granularity" => "line"}
      }

      assert {:error, :invalid_side} = Threads.save_draft(review, author, params)
    end

    test "rejects missing anchor granularity" do
      %{author: author, review: review} = setup_review!()

      params = %{
        "file_path" => "lib/foo.ex",
        "side" => "new",
        "body" => "hi",
        "thread_anchor" => %{}
      }

      assert {:error, :invalid_anchor} = Threads.save_draft(review, author, params)
    end
  end

  describe "publish_all_drafts/3" do
    test "flips every draft + summary to published in one transaction" do
      %{author: author, review: review} = setup_review!()
      Phoenix.PubSub.subscribe(Reviews.PubSub, "review:#{review.slug}")

      params_a = %{
        "file_path" => "lib/foo.ex",
        "side" => "new",
        "body" => "comment A",
        "thread_anchor" => %{
          "granularity" => "line",
          "line_text" => "  def bar, do: :new",
          "context_before" => [],
          "context_after" => [],
          "line_number_hint" => 2
        }
      }

      params_b =
        params_a
        |> Map.put("body", "comment B")
        |> Map.put("thread_anchor", %{
          "granularity" => "line",
          "line_text" => "defmodule Foo do",
          "context_before" => [],
          "context_after" => [],
          "line_number_hint" => 1
        })

      assert {:ok, %{thread: _ta}} = Threads.save_draft(review, author, params_a)
      assert {:ok, %{thread: _tb}} = Threads.save_draft(review, author, params_b)

      assert {:ok, %{comments: published_comments, summary: summary, threads: threads}} =
               Threads.publish_all_drafts(review, author, summary: "overall LGTM")

      assert length(published_comments) == 2
      assert Enum.all?(published_comments, &(&1.state == "published"))
      assert Enum.all?(published_comments, &(&1.published_at != nil))
      assert summary.body == "overall LGTM"
      assert summary.state == "published"
      assert length(threads) == 2

      # Drafts are gone (no Comment with state="draft" for this author).
      remaining =
        Repo.all(from c in Comment, where: c.author_id == ^author.id and c.state == "draft")

      assert remaining == []

      # PubSub broadcast happened once per thread.
      assert_receive {:thread_published, _t1}
      assert_receive {:thread_published, _t2}
    end

    test "returns ok with empty lists when there are no drafts" do
      %{author: author, review: review} = setup_review!()

      assert {:ok, %{comments: [], summary: nil, threads: []}} =
               Threads.publish_all_drafts(review, author)
    end
  end

  describe "list_drafts_for/2 and list_published_threads/1" do
    test "drafts are private per-author; published threads visible to all" do
      %{author: author, review: review} = setup_review!()

      {:ok, other_user} =
        Accounts.upsert_from_github(%{
          github_id: 99_999,
          username: "other",
          email: "other@example.com",
          avatar_url: nil
        })

      params = %{
        "file_path" => "lib/foo.ex",
        "side" => "new",
        "body" => "draft from author",
        "thread_anchor" => %{
          "granularity" => "line",
          "line_text" => "x",
          "context_before" => [],
          "context_after" => [],
          "line_number_hint" => 1
        }
      }

      {:ok, _} = Threads.save_draft(review, author, params)

      assert [%{thread: _, comment: c}] = Threads.list_drafts_for(review, author)
      assert c.body == "draft from author"

      # The other user sees nothing as a draft (private), and nothing as
      # published (it hasn't been published yet).
      assert Threads.list_drafts_for(review, other_user) == []
      assert Threads.list_published_threads(review.id) == []

      {:ok, _} = Threads.publish_all_drafts(review, author)

      assert [thread] = Threads.list_published_threads(review.id)
      assert length(thread.comments) == 1
      assert hd(thread.comments).body == "draft from author"

      # Now the author has no drafts left.
      assert Threads.list_drafts_for(review, author) == []
    end
  end

  describe "delete_draft/2" do
    test "removes a draft comment and its thread if no comments remain" do
      %{author: author, review: review} = setup_review!()

      params = %{
        "file_path" => "lib/foo.ex",
        "side" => "new",
        "body" => "to delete",
        "thread_anchor" => %{
          "granularity" => "line",
          "line_text" => "x",
          "context_before" => [],
          "context_after" => [],
          "line_number_hint" => 1
        }
      }

      {:ok, %{thread: thread, comment: comment}} = Threads.save_draft(review, author, params)

      assert {:ok, :ok} = Threads.delete_draft(comment.id, author)
      assert Repo.get(Comment, comment.id) == nil
      assert Repo.get(Thread, thread.id) == nil
    end

    test "rejects deleting another user's draft" do
      %{author: author, review: review} = setup_review!()

      {:ok, other} =
        Accounts.upsert_from_github(%{
          github_id: 42,
          username: "x",
          email: "x@e.com",
          avatar_url: nil
        })

      params = %{
        "file_path" => "lib/foo.ex",
        "side" => "new",
        "body" => "draft",
        "thread_anchor" => %{
          "granularity" => "line",
          "line_text" => "x",
          "context_before" => [],
          "context_after" => [],
          "line_number_hint" => 1
        }
      }

      {:ok, %{comment: comment}} = Threads.save_draft(review, author, params)
      assert {:error, :not_found} = Threads.delete_draft(comment.id, other)
      assert Repo.get(Comment, comment.id)
    end
  end
end
