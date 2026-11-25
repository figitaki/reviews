defmodule Reviews.ReviewersTest do
  use Reviews.DataCase, async: true

  alias Reviews.Accounts
  alias Reviews.GitHubUsersStub
  alias Reviews.PacketSectionDecisions
  alias Reviews.Reviewers
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.ReviewPacket

  @diff "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"

  setup do
    owner = human(1_001, "owner")

    {:ok, %{review: review, patchset: patchset}} =
      ReviewsContext.create_review_with_initial_patchset(owner, %{
        title: "Packet review",
        raw_diff: @diff,
        packet: %{
          "format_version" => 1,
          "title" => "Packet",
          "sections" => [
            %{
              "title" => "Main",
              "rows" => [%{"kind" => "hunk", "path" => "foo", "hunk_index" => 1}]
            }
          ]
        }
      })

    section = ReviewPacket.section_at(patchset.packet, 0)
    GitHubUsersStub.stub(%{"owner" => 1_001, "Sam" => 2_002, "riley" => 3_003})

    %{owner: owner, review: review, patchset: patchset, section: section}
  end

  test "an added reviewer and their agents can decide; others cannot", ctx do
    sam = human(2_002, "sam")

    {:ok, sam_agent} =
      Accounts.create_agent_identity(sam.owner_user, %{display_name: "Codex", handle: "codex"})

    stranger = human(4_004, "stranger")

    assert {:error, :forbidden} = decide(ctx, sam, "approved")

    # GitHub's spelling of the login is kept, whatever case the owner typed.
    assert {:ok, [%{login: "sam", status: "active"}]} =
             Reviewers.add(ctx.review, ctx.owner, "@SAM")

    assert {:ok, decision} = decide(ctx, sam_agent, "approved")
    assert decision.author_id == sam_agent.id
    assert decision.account_id == sam.owner_user_id
    assert {:error, :forbidden} = decide(ctx, stranger, "approved")

    # The owner keeps deciding, on its own account's row.
    assert {:ok, _} = decide(ctx, ctx.owner, "denied")
    assert length(Repo.all(Reviews.Reviews.PacketSectionDecision)) == 2
  end

  test "an invite is claimed by the GitHub ID, never by the login text", ctx do
    assert {:ok, [%{login: "riley", status: "invited", identity: nil}]} =
             Reviewers.add(ctx.review, ctx.owner, "riley")

    # Someone else who now holds the login "riley" on GitHub does not get the seat.
    impostor = human(9_999, "riley")
    assert {:error, :forbidden} = decide(ctx, impostor, "approved")
    assert [%{status: "invited"}] = Reviewers.list(ctx.review)

    # The invited account signs up later, under a new login.
    riley = human(3_003, "riley-renamed")
    assert [%{status: "active", login: "riley-renamed"}] = Reviewers.list(ctx.review)
    assert {:ok, _} = decide(ctx, riley, "approved")
  end

  test "removing a reviewer stops their decisions but keeps them", ctx do
    sam = human(2_002, "sam")
    {:ok, _} = Reviewers.add(ctx.review, ctx.owner, "sam")
    {:ok, _} = decide(ctx, sam, "approved")

    assert {:ok, []} = Reviewers.remove(ctx.review, ctx.owner, "Sam")
    assert {:error, :forbidden} = decide(ctx, sam, "denied")
    assert [%{status: "approved"}] = PacketSectionDecisions.list_for_review(ctx.review, sam)

    # Removing someone who is not a reviewer changes nothing.
    assert {:ok, []} = Reviewers.remove(ctx.review, ctx.owner, "sam")
  end

  test "only the owner manages reviewers, and not their own account", ctx do
    sam = human(2_002, "sam")
    {:ok, _} = Reviewers.add(ctx.review, ctx.owner, "sam")

    assert {:error, :forbidden} = Reviewers.add(ctx.review, sam, "riley")
    assert {:error, :forbidden} = Reviewers.remove(ctx.review, sam, "sam")
    assert {:error, :reviewer_is_owner} = Reviewers.add(ctx.review, ctx.owner, "owner")
    assert {:error, :github_user_not_found} = Reviewers.add(ctx.review, ctx.owner, "nobody")
    assert {:error, :github_user_not_found} = Reviewers.add(ctx.review, ctx.owner, "bad login")

    # Adding twice keeps one row.
    assert {:ok, [%{login: "sam"}]} = Reviewers.add(ctx.review, ctx.owner, "sam")
  end

  test "a GitHub outage is reported, not treated as an unknown login", ctx do
    Req.Test.stub(Reviews.GitHubUsers, &Plug.Conn.send_resp(&1, 502, "bad gateway"))
    assert {:error, :github_unavailable} = Reviewers.add(ctx.review, ctx.owner, "sam")
  end

  defp decide(ctx, actor, status),
    do: PacketSectionDecisions.decide(ctx.review, ctx.patchset, actor, ctx.section, status)

  defp human(github_id, login) do
    {:ok, user} = Accounts.upsert_from_github(%{github_id: github_id, username: login})
    user |> Accounts.human_identity_for() |> Repo.preload(:owner_user)
  end
end
