defmodule Reviews.ReviewDeletionTest.RecordingHook do
  @moduledoc false
  @behaviour Reviews.Reviews.DeletionHook

  alias Reviews.Reviews.Review

  # Reports whether the review row still existed when the hook ran, then
  # returns whatever the test asked for.
  @impl true
  def before_review_delete(%Review{} = review) do
    send(self(), {:hook_ran, review.slug, Reviews.Repo.get(Review, review.id) != nil})
    Process.get(:deletion_hook_result, :ok)
  end
end

defmodule Reviews.ReviewDeletionTest do
  # Not async: the hook tests change application config.
  use Reviews.DataCase

  alias Reviews.Accounts
  alias Reviews.PacketHunkViews
  alias Reviews.PacketSectionDecisions
  alias Reviews.Principal
  alias Reviews.ReviewPacket
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.Review
  alias Reviews.ReviewDeletionTest.RecordingHook
  alias Reviews.Threads

  @diff "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"
  @packet %{
    "format_version" => 1,
    "title" => "Packet",
    "sections" => [
      %{"title" => "Main", "rows" => [%{"kind" => "hunk", "path" => "foo", "hunk_index" => 1}]}
    ]
  }

  setup do
    owner = user("owner")

    {:ok, agent} =
      Accounts.create_agent_identity(owner, %{handle: "codex", display_name: "Codex"})

    stranger = user("stranger")

    {:ok, stranger_agent} =
      Accounts.create_agent_identity(stranger, %{handle: "helper", display_name: "Helper"})

    %{
      owner: owner,
      human: Accounts.human_identity_for(owner),
      agent: agent,
      stranger: Accounts.human_identity_for(stranger),
      stranger_agent: stranger_agent
    }
  end

  describe "delete_review/2" do
    test "leaves the database as it was before the review existed", ctx do
      # Another review with the same kinds of rows must survive untouched.
      _kept = populated_review(ctx)
      before = row_counts()

      review = populated_review(ctx)
      assert row_counts() != before

      assert {:ok, %Review{}} = ReviewsContext.delete_review(review, ctx.human)

      # Every table except the tombstone is back to its earlier row count, so
      # no patchset, file, thread, comment, decision or viewed-hunk row is left
      # behind, and nothing outside the review (users, identities) was removed.
      assert row_counts() == Map.update!(before, "deleted_reviews", &(&1 + 1))
      assert ReviewsContext.get_review_by_slug(review.slug) == nil
      assert ReviewsContext.not_found_reason(review.slug) == :review_deleted
      assert ReviewsContext.not_found_reason("never-existed") == :review_not_found
    end

    test "the owner's agent identity may delete, as the account owns the review", ctx do
      review = populated_review(ctx)
      principal = Principal.new(ctx.agent, :api_token, ctx.owner)

      assert {:ok, _} = ReviewsContext.delete_review(review, principal)
      assert ReviewsContext.deleted?(review.slug)
    end

    test "refuses everyone but the owner's account and writes nothing", ctx do
      review = populated_review(ctx)
      before = row_counts()

      # A delegated (OAuth) grant of the owner holds only the comment scope.
      delegated = Principal.delegated(ctx.human, ctx.owner, ["comments:write"], nil, :poppy)

      for actor <- [ctx.stranger, ctx.stranger_agent, delegated, nil] do
        assert ReviewsContext.delete_review(review, actor) == {:error, :forbidden}
      end

      assert row_counts() == before
      refute ReviewsContext.deleted?(review.slug)
    end

    test "a second deletion of the same review reports it as deleted", ctx do
      review = populated_review(ctx)
      assert {:ok, _} = ReviewsContext.delete_review(review, ctx.human)
      assert ReviewsContext.delete_review(review, ctx.human) == {:error, :review_deleted}
    end

    test "tells viewers of the review", ctx do
      review = populated_review(ctx)
      Phoenix.PubSub.subscribe(Reviews.PubSub, "review:#{review.slug}")

      assert {:ok, _} = ReviewsContext.delete_review(review, ctx.human)
      assert_receive {:review_deleted, slug} when slug == review.slug
    end
  end

  describe "deletion hooks" do
    setup do
      Application.put_env(:reviews, :review_deletion_hooks, [RecordingHook])
      on_exit(fn -> Application.delete_env(:reviews, :review_deletion_hooks) end)
    end

    test "run inside the deletion, before any row is deleted", ctx do
      review = populated_review(ctx)

      assert {:ok, _} = ReviewsContext.delete_review(review, ctx.human)
      assert_received {:hook_ran, slug, true} when slug == review.slug
    end

    test "an error rolls the whole deletion back", ctx do
      review = populated_review(ctx)
      before = row_counts()
      Process.put(:deletion_hook_result, {:error, :code_storage_unavailable})

      assert ReviewsContext.delete_review(review, ctx.human) ==
               {:error, :code_storage_unavailable}

      assert row_counts() == before
      assert ReviewsContext.get_review_by_slug(review.slug)
    end

    test "do not run when the actor may not delete", ctx do
      review = populated_review(ctx)

      assert {:error, :forbidden} = ReviewsContext.delete_review(review, ctx.stranger)
      refute_received {:hook_ran, _, _}
    end
  end

  test "deletion_summary counts other accounts' comments, not the owner's agents'", ctx do
    review = populated_review(ctx)

    assert ReviewsContext.deletion_summary(review) == %{
             patchsets: 2,
             threads: 2,
             comments: 5,
             other_comments: 3,
             other_authors: Enum.sort(["helper", ctx.stranger.handle])
           }
  end

  # A review with two patchsets and every kind of row a review owns: threads
  # on both patchsets with comments by the owner, the owner's agent, another
  # person and another person's agent; a section decision; viewed hunks.
  defp populated_review(ctx) do
    {:ok, %{review: review, patchset: first}} =
      ReviewsContext.create_review_with_initial_patchset(ctx.human, %{
        title: "To delete",
        raw_diff: @diff,
        packet: @packet
      })

    {:ok, second} =
      ReviewsContext.append_patchset_unchecked(review, %{raw_diff: @diff, packet: @packet})

    {:ok, %{thread: owners}} = comment(review, ctx.human, %{"revision" => 1})
    {:ok, _} = comment(review, ctx.agent, %{"thread_id" => owners.id})
    {:ok, _} = comment(review, ctx.stranger, %{"thread_id" => owners.id})
    {:ok, %{thread: strangers}} = comment(review, ctx.stranger, %{})
    {:ok, _} = comment(review, ctx.stranger_agent, %{"thread_id" => strangers.id})

    section = ReviewPacket.section_at(second.packet, 0)
    {:ok, _} = PacketSectionDecisions.decide(review, second, ctx.human, section, "approved")

    for {identity, patchset} <- [{ctx.human, first}, {ctx.stranger, second}] do
      {:ok, _} =
        PacketHunkViews.mark_viewed(review, patchset, identity, %{
          file_path: "foo",
          row_ref: "foo#1",
          hunk_fingerprint: "fp",
          hunk_index: 1
        })
    end

    review
  end

  defp comment(review, identity, params) do
    Threads.publish_comment(
      review,
      identity,
      Map.merge(
        %{
          "file_path" => "foo",
          "side" => "new",
          "body" => "A comment",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
        },
        params
      )
    )
  end

  defp row_counts do
    %{rows: tables} =
      Repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'schema_migrations'"
      )

    Map.new(tables, fn [table] ->
      %{rows: [[count]]} = Repo.query!(~s[SELECT count(*) FROM "#{table}"])
      {table, count}
    end)
  end

  defp user(name) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 2_000_000 + unique,
        username: "#{name}-#{unique}",
        email: "#{name}@example.com"
      })

    user
  end
end
