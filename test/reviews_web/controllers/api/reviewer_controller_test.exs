defmodule ReviewsWeb.Api.ReviewerControllerTest do
  use ReviewsWeb.ConnCase, async: true

  alias Reviews.Accounts
  alias Reviews.GitHubUsersStub
  alias Reviews.Reviews, as: ReviewsContext

  @diff "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"

  setup do
    {:ok, owner} = Accounts.upsert_from_github(%{github_id: 5_001, username: "owner"})

    {:ok, agent} =
      Accounts.create_agent_identity(owner, %{display_name: "Codex", handle: "codex"})

    {:ok, _token, owner_raw} = Accounts.mint_token(owner, %{name: "agent", identity_id: agent.id})

    {:ok, sam} = Accounts.upsert_from_github(%{github_id: 5_002, username: "sam"})
    {:ok, _token, sam_raw} = Accounts.mint_token(sam, %{name: "human"})

    {:ok, %{review: review}} =
      ReviewsContext.create_review_with_initial_patchset(agent, %{
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

    GitHubUsersStub.stub(%{"owner" => 5_001, "sam" => 5_002, "riley" => 5_003})
    %{review: review, owner_raw: owner_raw, sam_raw: sam_raw}
  end

  test "the owner's agent adds reviewers who can then decide; anyone can list them", ctx do
    conn = authed(ctx.owner_raw) |> put(~p"/api/v1/reviews/#{ctx.review.slug}/reviewers/sam")

    assert %{"reviewers" => [%{"login" => "sam", "status" => "active"}]} =
             json_response(conn, 200)

    conn = authed(ctx.owner_raw) |> put(~p"/api/v1/reviews/#{ctx.review.slug}/reviewers/riley")

    assert %{
             "reviewers" => [
               %{"login" => "sam"},
               %{"login" => "riley", "status" => "invited", "identity" => nil}
             ]
           } =
             json_response(conn, 200)

    conn =
      authed(ctx.sam_raw)
      |> post(~p"/api/v1/reviews/#{ctx.review.slug}/sections/0/decision", %{
        "status" => "approved"
      })

    assert %{"status" => "approved"} = json_response(conn, 200)

    # Signed out, the list and the review snapshot both show the reviewers.
    assert %{"reviewers" => [_, _]} =
             build_conn()
             |> get(~p"/api/v1/reviews/#{ctx.review.slug}/reviewers")
             |> json_response(200)

    assert %{"reviewers" => [%{"login" => "sam", "github_id" => 5_002}, %{"login" => "riley"}]} =
             build_conn() |> get(~p"/api/v1/reviews/#{ctx.review.slug}") |> json_response(200)
  end

  test "removing a reviewer returns 403 on their next decision", ctx do
    authed(ctx.owner_raw) |> put(~p"/api/v1/reviews/#{ctx.review.slug}/reviewers/sam")

    conn = authed(ctx.owner_raw) |> delete(~p"/api/v1/reviews/#{ctx.review.slug}/reviewers/sam")
    assert %{"reviewers" => []} = json_response(conn, 200)

    conn =
      authed(ctx.sam_raw)
      |> post(~p"/api/v1/reviews/#{ctx.review.slug}/sections/0/decision", %{
        "status" => "approved"
      })

    assert json_response(conn, 403)
  end

  test "reviewers cannot manage reviewers, and errors carry stable codes", ctx do
    authed(ctx.owner_raw) |> put(~p"/api/v1/reviews/#{ctx.review.slug}/reviewers/sam")

    conn = authed(ctx.sam_raw) |> put(~p"/api/v1/reviews/#{ctx.review.slug}/reviewers/riley")

    assert %{
             "error_code" => "forbidden",
             "error_detail" => "Only the review owner can add or remove reviewers"
           } =
             json_response(conn, 403)

    conn = authed(ctx.owner_raw) |> put(~p"/api/v1/reviews/#{ctx.review.slug}/reviewers/nobody")
    assert %{"error_code" => "github_user_not_found"} = json_response(conn, 404)

    conn = authed(ctx.owner_raw) |> put(~p"/api/v1/reviews/#{ctx.review.slug}/reviewers/owner")
    assert %{"error_code" => "reviewer_is_owner"} = json_response(conn, 422)

    conn = build_conn() |> put(~p"/api/v1/reviews/#{ctx.review.slug}/reviewers/sam")
    assert json_response(conn, 401)
  end

  defp authed(raw) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end
end
