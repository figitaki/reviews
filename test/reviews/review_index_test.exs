defmodule Reviews.ReviewIndexTest do
  use Reviews.DataCase, async: true

  import Reviews.ReviewIndexFixtures

  alias Reviews.ReviewIndex
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads.Thread

  defp slugs(%{entries: entries}), do: Enum.map(entries, & &1.review.slug)

  describe "visibility" do
    test "lists reviews the viewer wrote or took part in, and nothing else" do
      carey = user!("carey")
      conner = user!("conner")
      stranger = user!("stranger")

      mine = review!(carey, "Mine", at: at(30))
      commented = review!(conner, "Conner asked me", at: at(20))
      unrelated = review!(stranger, "Not for me", at: at(10))

      comment!(commented, carey)

      result = ReviewsContext.list_reviews(carey)

      assert slugs(result) == [commented.slug, mine.slug]
      refute unrelated.slug in slugs(result)
    end

    test "public visibility does not put a review in other people's lists" do
      carey = user!("carey")
      stranger = user!("stranger")
      review = review!(stranger, "Public one")
      review |> Ecto.Changeset.change(visibility: "public") |> Repo.update!()

      assert slugs(ReviewsContext.list_reviews(carey)) == []
    end

    test "a user sees reviews from their agent identities" do
      carey = user!("carey")
      agent = agent!(carey, "codex")
      review = review!(agent, "Agent work")

      assert [entry] = ReviewsContext.list_reviews(carey).entries
      assert entry.review.slug == review.slug
      assert entry.role == "authored"
      assert entry.review.author.handle == "codex"
    end

    test "an agent identity sees only its own reviews" do
      carey = user!("carey")
      agent = agent!(carey, "codex")
      agent_review = review!(agent, "Agent work")
      _human_review = review!(carey, "Human work")

      assert slugs(ReviewsContext.list_reviews(agent)) == [agent_review.slug]
    end

    test "section decisions and viewed hunks count as taking part" do
      carey = user!("carey")
      conner = user!("conner")
      human = human!(carey)
      decided = review!(conner, "Decided")
      viewed = review!(conner, "Viewed")

      Repo.insert!(%Reviews.Reviews.PacketSectionDecision{
        review_id: decided.id,
        patchset_id: ReviewsContext.latest_patchset_id(decided),
        author_id: human.id,
        section_index: 0,
        section_title: "Intro",
        section_fingerprint: "abc",
        status: "approved"
      })

      Repo.insert!(%Reviews.Reviews.PacketHunkView{
        review_id: viewed.id,
        patchset_id: ReviewsContext.latest_patchset_id(viewed),
        author_id: human.id,
        file_path: "lib/foo.ex",
        row_ref: "r1",
        hunk_fingerprint: "h1",
        hunk_index: 1
      })

      assert Enum.sort(slugs(ReviewsContext.list_reviews(carey))) ==
               Enum.sort([decided.slug, viewed.slug])
    end

    test "a nil viewer gets an empty list" do
      user = user!("carey")
      review!(user, "Mine")

      assert %{entries: [], next_offset: nil} = ReviewsContext.list_reviews(nil)
    end
  end

  describe "entries" do
    test "carry patchset and thread counts" do
      carey = user!("carey")
      conner = user!("conner")
      review = review!(carey, "Counts", at: at(60))
      patchset!(review, at(5))
      comment!(review, conner)
      comment!(review, conner, "Second thread")

      [thread | _] = Repo.all(from t in Thread, where: t.review_id == ^review.id)
      thread |> Ecto.Changeset.change(status: "resolved") |> Repo.update!()

      assert [entry] = ReviewsContext.list_reviews(carey).entries
      assert entry.patchset_count == 2
      assert entry.latest_patchset_number == 2
      assert entry.thread_count == 2
      assert entry.open_thread_count == 1
      assert entry.last_pushed_at == at(5)
      assert entry.updated_at == at(5)
    end
  end

  describe "sorting" do
    test "newest push first, even when the review row is older" do
      carey = user!("carey")
      old = review!(carey, "Old", at: at(120))
      new = review!(carey, "New", at: at(60))
      patchset!(old, at(1))

      assert slugs(ReviewsContext.list_reviews(carey)) == [old.slug, new.slug]
    end
  end

  describe "filters" do
    setup do
      carey = user!("carey")
      conner = user!("conner")
      agent = agent!(carey, "codex")

      authored = review!(carey, "Speed up user lookup", at: at(50))
      by_agent = review!(agent, "Agent cleanup", at: at(40))
      involved = review!(conner, "Add billing export", at: at(30))
      comment!(involved, carey, "Question", at: at(25))

      %{carey: carey, authored: authored, by_agent: by_agent, involved: involved}
    end

    test "role", ctx do
      assert Enum.sort(slugs(ReviewsContext.list_reviews(ctx.carey, %{"role" => "authored"}))) ==
               Enum.sort([ctx.authored.slug, ctx.by_agent.slug])

      assert slugs(ReviewsContext.list_reviews(ctx.carey, %{"role" => "involved"})) == [
               ctx.involved.slug
             ]
    end

    test "author handle, with or without @, any case", ctx do
      assert slugs(ReviewsContext.list_reviews(ctx.carey, %{"author" => "@Codex"})) == [
               ctx.by_agent.slug
             ]

      assert slugs(ReviewsContext.list_reviews(ctx.carey, %{"author" => "conner"})) == [
               ctx.involved.slug
             ]
    end

    test "search matches title or slug", ctx do
      assert slugs(ReviewsContext.list_reviews(ctx.carey, %{"q" => "BILLING"})) == [
               ctx.involved.slug
             ]

      assert slugs(ReviewsContext.list_reviews(ctx.carey, %{"q" => ctx.authored.slug})) == [
               ctx.authored.slug
             ]

      assert slugs(ReviewsContext.list_reviews(ctx.carey, %{"q" => "100%_"})) == []
    end

    test "status open keeps reviews with open threads", ctx do
      assert slugs(ReviewsContext.list_reviews(ctx.carey, %{"status" => "open"})) == [
               ctx.involved.slug
             ]
    end

    test "status updated keeps reviews with a patchset newer than your last action", ctx do
      assert slugs(ReviewsContext.list_reviews(ctx.carey, %{"status" => "updated"})) == []

      patchset!(ctx.involved, at(1))

      assert [entry] = ReviewsContext.list_reviews(ctx.carey, %{"status" => "updated"}).entries
      assert entry.review.slug == ctx.involved.slug
      assert entry.has_new_patchset
    end
  end

  describe "pagination" do
    test "limit and offset with next_offset" do
      carey = user!("carey")
      for n <- 1..5, do: review!(carey, "Review #{n}", at: at(n))

      first = ReviewsContext.list_reviews(carey, %{"limit" => "2"})
      assert length(first.entries) == 2
      assert first.next_offset == 2

      last = ReviewsContext.list_reviews(carey, %{"limit" => "2", "offset" => "4"})
      assert length(last.entries) == 1
      assert last.next_offset == nil

      all = ReviewsContext.list_reviews(carey, %{"limit" => "10"}) |> slugs()

      paged =
        Enum.flat_map([0, 2, 4], fn offset ->
          slugs(ReviewsContext.list_reviews(carey, %{"limit" => "2", "offset" => offset}))
        end)

      assert paged == all
    end
  end

  describe "normalize_filters/1" do
    test "fills in defaults" do
      assert {:ok, %{role: "all", status: "all", author: nil, q: nil, limit: 25, offset: 0}} =
               ReviewIndex.normalize_filters(%{"q" => "  ", "author" => ""})
    end

    test "reports bad values" do
      assert {:error, errors} =
               ReviewIndex.normalize_filters(%{
                 "role" => "owner",
                 "status" => "closed",
                 "limit" => "500",
                 "offset" => "-1"
               })

      assert errors.role =~ "all, authored, involved"
      assert errors.status =~ "all, open, updated"
      assert errors.limit == "must be 100 or less"
      assert errors.offset == "must be 0 or more"
    end

    test "lenient mode drops bad values" do
      assert %{role: "all", limit: 25, q: "x"} =
               ReviewIndex.normalize_filters_lenient(%{"role" => "x", "limit" => "y", "q" => "x"})
    end
  end
end
