defmodule ReviewsWeb.ReviewReviewersLiveTest do
  use ReviewsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Reviews.Accounts
  alias Reviews.GitHubUsersStub
  alias Reviews.PacketSectionDecisions
  alias Reviews.Reviewers
  alias Reviews.Reviews, as: ReviewsContext

  setup do
    {:ok, owner} = Accounts.upsert_from_github(%{github_id: 6_001, username: "owner"})
    {:ok, sam} = Accounts.upsert_from_github(%{github_id: 6_002, username: "sam"})
    owner_identity = Accounts.human_identity_for(owner)

    {:ok, %{review: review}} =
      ReviewsContext.create_review_with_initial_patchset(owner_identity, %{
        title: "Packet",
        raw_diff:
          "diff --git a/lib/p.ex b/lib/p.ex\n--- a/lib/p.ex\n+++ b/lib/p.ex\n@@ -1 +1 @@\n-old\n+new\n",
        packet: %{
          "format_version" => 1,
          "title" => "Packet walkthrough",
          "sections" => [
            %{
              "title" => "Main change",
              "rows" => [%{"kind" => "hunk", "path" => "lib/p.ex", "hunk_index" => 1}]
            }
          ]
        }
      })

    GitHubUsersStub.stub(%{"sam" => 6_002, "riley" => 6_003})
    %{owner: owner, owner_identity: owner_identity, sam: sam, review: review}
  end

  test "the owner adds and removes reviewers from the review header", ctx do
    {:ok, view, _html} = ctx.conn |> signed_in(ctx.owner) |> live(~p"/r/#{ctx.review.slug}")
    Req.Test.allow(Reviews.GitHubUsers, self(), view.pid)

    assert has_element?(view, "#review-reviewers-empty")

    view |> form("#add-reviewer-form", reviewer: %{login: "riley"}) |> render_submit()
    assert has_element?(view, "#reviewer-6003", "Invited")

    view |> form("#add-reviewer-form", reviewer: %{login: "nobody"}) |> render_submit()
    assert render(view) =~ "No GitHub account has that login."
    assert has_element?(view, "#add-reviewer-login[value=nobody]")

    view |> element("#reviewer-6003 button[phx-click=remove_reviewer]") |> render_click()
    refute has_element?(view, "#reviewer-6003")
  end

  test "a reviewer sees the list without controls and can decide sections", ctx do
    {:ok, _} = Reviewers.add(ctx.review, ctx.owner_identity, "sam")
    {:ok, view, _html} = ctx.conn |> signed_in(ctx.sam) |> live(~p"/r/#{ctx.review.slug}")

    assert has_element?(view, "#reviewer-6002")
    refute has_element?(view, "#add-reviewer-form")
    refute has_element?(view, "#reviewer-6002 button")

    render_hook(view, "set_section_status", %{"section_index" => "0", "status" => "approved"})
    assert [%{status: "approved"}] = PacketSectionDecisions.list_for_review(ctx.review, ctx.sam)
  end

  test "an open page picks up being added as a reviewer", ctx do
    {:ok, view, _html} = ctx.conn |> signed_in(ctx.sam) |> live(~p"/r/#{ctx.review.slug}")
    refute has_element?(view, "#review-reviewers")

    {:ok, _} = Reviewers.add(ctx.review, ctx.owner_identity, "sam")
    assert has_element?(view, "#reviewer-6002")

    render_hook(view, "set_section_status", %{"section_index" => "0", "status" => "denied"})
    assert [%{status: "denied"}] = PacketSectionDecisions.list_for_review(ctx.review, ctx.sam)
  end

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{current_user_id: user.id})
end
