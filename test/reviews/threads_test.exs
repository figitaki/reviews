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

  defp line_params(body \\ "Should be `:newer`?") do
    %{
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
    }
  end

  describe "publish_comment/3" do
    test "creates a thread + comment from a valid payload" do
      %{author: author, review: review} = setup_review!()

      assert {:ok, %{thread: %Thread{} = thread, comment: %Comment{} = comment}} =
               Threads.publish_comment(review, author, line_params())

      assert thread.file_path == "lib/foo.ex"
      assert thread.side == "new"
      assert thread.anchor["granularity"] == "line"
      assert comment.body == "Should be `:newer`?"
      assert comment.author_id == author.id
    end

    test "appends replies to an existing thread" do
      %{author: author, review: review} = setup_review!()

      {:ok, %{thread: thread, comment: first}} =
        Threads.publish_comment(review, author, line_params("first"))

      assert {:ok, %{thread: reply_thread, comment: second}} =
               Threads.publish_comment(
                 review,
                 author,
                 line_params("reply") |> Map.put("thread_id", thread.id)
               )

      assert reply_thread.id == thread.id
      assert second.id != first.id

      assert [listed_first, listed_second] =
               Threads.list_published_threads(review.id) |> hd() |> Map.get(:comments)

      assert listed_first.id == first.id
      assert listed_second.id == second.id
    end

    test "rejects empty body" do
      %{author: author, review: review} = setup_review!()

      assert {:error, :empty_body} =
               Threads.publish_comment(review, author, line_params("   "))
    end

    test "rejects invalid side" do
      %{author: author, review: review} = setup_review!()

      params = line_params("hi") |> Map.put("side", "middle")

      assert {:error, :invalid_side} = Threads.publish_comment(review, author, params)
    end

    test "rejects missing anchor granularity" do
      %{author: author, review: review} = setup_review!()

      params = line_params("hi") |> Map.put("thread_anchor", %{})

      assert {:error, :invalid_anchor} = Threads.publish_comment(review, author, params)
    end

    test "broadcasts the updated thread" do
      %{author: author, review: review} = setup_review!()
      Phoenix.PubSub.subscribe(Reviews.PubSub, "review:#{review.slug}")

      assert {:ok, _} = Threads.publish_comment(review, author, line_params("hello"))
      assert_receive {:thread_published, %Thread{}}
    end
  end

  describe "list_published_threads/1" do
    test "comments are visible immediately to every viewer" do
      %{author: author, review: review} = setup_review!()

      {:ok, _} = Threads.publish_comment(review, author, line_params("published now"))

      assert [thread] = Threads.list_published_threads(review.id)
      assert length(thread.comments) == 1
      assert hd(thread.comments).body == "published now"
    end
  end
end
