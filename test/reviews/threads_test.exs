defmodule Reviews.ThreadsTest do
  use Reviews.DataCase, async: true

  alias Reviews.Accounts
  alias Reviews.Repo
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

  defp agent_for(user) do
    Accounts.create_agent_identity(user, %{
      handle: "agent-#{System.unique_integer([:positive])}",
      display_name: "Agent"
    })
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
      assert comment.author_id == Accounts.human_identity_for(author).id
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

    test "rejects false reply IDs with either key type instead of creating a thread" do
      %{author: author, review: review} = setup_review!()

      for key <- ["thread_id", :thread_id] do
        params = Map.put(line_params("reply"), key, false)
        assert {:error, :thread_not_found} = Threads.publish_comment(review, author, params)
      end

      assert Threads.list_published_threads(review.id) == []
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

  describe "update_status/4" do
    test "resolves a thread and records who resolved it" do
      %{author: author, review: review} = setup_review!()
      {:ok, %{thread: thread}} = Threads.publish_comment(review, author, line_params("nit"))
      Phoenix.PubSub.subscribe(Reviews.PubSub, "review:#{review.slug}")

      assert {:ok, %Thread{} = updated} =
               Threads.update_status(review, thread.id, author, "resolved")

      identity = Accounts.human_identity_for(author)

      assert updated.id == thread.id
      assert updated.status == "resolved"
      assert updated.resolved_by_id == identity.id
      assert %DateTime{} = updated.resolved_at
      assert updated.resolved_by.handle == author.username
      assert_receive {:thread_updated, %Thread{id: thread_id, status: "resolved"}}
      assert thread_id == thread.id
    end

    test "reopens a resolved thread and clears resolution metadata" do
      %{author: author, review: review} = setup_review!()
      {:ok, %{thread: thread}} = Threads.publish_comment(review, author, line_params("nit"))
      {:ok, resolved} = Threads.update_status(review, thread.id, author, "resolved")

      assert {:ok, reopened} = Threads.update_status(review, resolved.id, author, "open")

      assert reopened.status == "open"
      assert reopened.resolved_by_id == nil
      assert reopened.resolved_at == nil
    end

    test "rejects threads from another review" do
      %{author: author, review: review} = setup_review!()
      %{review: other_review} = setup_review!()
      {:ok, %{thread: thread}} = Threads.publish_comment(review, author, line_params("nit"))

      assert {:error, :not_found} =
               Threads.update_status(other_review, thread.id, author, "resolved")
    end

    test "rejects invalid statuses" do
      %{author: author, review: review} = setup_review!()
      {:ok, %{thread: thread}} = Threads.publish_comment(review, author, line_params("nit"))

      assert {:error, :invalid_status} =
               Threads.update_status(review, thread.id, author, "closed")

      assert %Thread{status: "open"} = Repo.get(Thread, thread.id)
    end

    test "re-resolving keeps the original resolver and stays quiet" do
      %{author: author, review: review} = setup_review!()
      %{author: other} = setup_review!()
      {:ok, %{thread: thread}} = Threads.publish_comment(review, other, line_params("nit"))
      {:ok, resolved} = Threads.update_status(review, thread.id, author, "resolved")

      Phoenix.PubSub.subscribe(Reviews.PubSub, "review:#{review.slug}")

      assert {:ok, again} = Threads.update_status(review, thread.id, other, "resolved")

      assert again.resolved_by_id == resolved.resolved_by_id
      assert again.resolved_at == resolved.resolved_at
      refute_receive {:thread_updated, _}
    end

    test "only the review owner's and the thread author's accounts may change status" do
      %{author: owner, review: review} = setup_review!()
      %{author: commenter} = setup_review!()
      %{author: stranger} = setup_review!()
      {:ok, owner_agent} = agent_for(owner)
      {:ok, commenter_agent} = agent_for(commenter)
      {:ok, stranger_agent} = agent_for(stranger)
      {:ok, %{thread: thread}} = Threads.publish_comment(review, commenter, line_params("nit"))
      Phoenix.PubSub.subscribe(Reviews.PubSub, "review:#{review.slug}")

      for actor <- [stranger, stranger_agent], status <- ["resolved", "open"] do
        assert {:error, :forbidden} = Threads.update_status(review, thread.id, actor, status)
      end

      assert %Thread{status: "open", resolved_by_id: nil} = Repo.get(Thread, thread.id)
      refute_receive {:thread_updated, _}

      for actor <- [owner, owner_agent, commenter, commenter_agent] do
        assert {:ok, %Thread{status: "resolved"}} =
                 Threads.update_status(review, thread.id, actor, "resolved")

        assert {:ok, %Thread{status: "open"}} =
                 Threads.update_status(review, thread.id, actor, "open")
      end
    end

    test "a thread started by an agent can be resolved by its owner's human identity" do
      %{review: review} = setup_review!()
      %{author: commenter} = setup_review!()
      %{author: stranger} = setup_review!()
      {:ok, commenter_agent} = agent_for(commenter)

      {:ok, %{thread: thread}} =
        Threads.publish_comment(review, commenter_agent, line_params("nit"))

      assert {:error, :forbidden} = Threads.update_status(review, thread.id, stranger, "resolved")

      assert {:ok, %Thread{status: "resolved"}} =
               Threads.update_status(review, thread.id, commenter, "resolved")
    end

    test "treats an out-of-range thread id as a miss rather than crashing" do
      %{author: author, review: review} = setup_review!()

      assert {:error, :not_found} =
               Threads.update_status(review, 99_999_999_999_999_999_999, author, "resolved")

      assert {:error, :not_found} =
               Threads.update_status(review, "99999999999999999999", author, "resolved")
    end

    test "delegated principals act only within their scopes" do
      %{review: review} = setup_review!()
      %{author: commenter} = setup_review!()
      {:ok, agent} = agent_for(commenter)
      attribution = %{"provider" => "poppy", "client_id" => "https://agent.example"}

      unscoped = Reviews.Principal.delegated(agent, commenter, [], attribution, :poppy)

      scoped =
        Reviews.Principal.delegated(agent, commenter, ["comments:write"], attribution, :poppy)

      assert {:error, :forbidden} = Threads.publish_comment(review, unscoped, line_params("no"))
      assert Threads.list_published_threads(review.id) == []

      assert {:ok, %{thread: thread, comment: comment}} =
               Threads.publish_comment(review, scoped, line_params("yes"))

      assert comment.author_id == agent.id
      assert comment.attribution == attribution

      # The same identity may resolve its own thread with an API token, but an
      # OAuth grant for comments does not extend to resolving.
      assert {:error, :forbidden} = Threads.update_status(review, thread.id, scoped, "resolved")

      assert {:ok, %Thread{status: "resolved"}} =
               Threads.update_status(review, thread.id, agent, "resolved")
    end
  end
end
