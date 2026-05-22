defmodule ReviewsWeb.Api.SectionDecisionControllerTest do
  use ReviewsWeb.ConnCase, async: true

  alias Reviews.Accounts
  alias Reviews.PacketSectionDecisions
  alias Reviews.Reviews, as: ReviewsContext

  setup do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 77_001,
        username: "bill",
        email: "bill@example.com",
        avatar_url: nil
      })

    {:ok, agent} = Accounts.create_agent_identity(user, %{display_name: "Codex", handle: "codex"})
    {:ok, _token, raw} = Accounts.mint_token(user, %{name: "agent", identity_id: agent.id})

    {:ok, %{review: review}} =
      ReviewsContext.create_review_with_initial_patchset(agent, %{
        title: "Packet review",
        raw_diff: "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n",
        packet: %{
          "format_version" => 1,
          "title" => "Packet",
          "sections" => [
            %{
              "title" => "Main section",
              "rows" => [%{"kind" => "hunk", "path" => "foo", "hunk_index" => 1}]
            }
          ]
        }
      })

    %{agent: agent, raw_token: raw, review: review}
  end

  test "sets a section decision under the token identity", %{
    conn: conn,
    raw_token: raw,
    agent: agent,
    review: review
  } do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/reviews/#{review.slug}/sections/0/decision", %{
        "status" => "approved"
      })

    assert %{"section_index" => 0, "status" => "approved"} = json_response(conn, 200)

    assert [%{author_id: author_id, status: "approved"}] =
             PacketSectionDecisions.list_for_review(review, agent)

    assert author_id == agent.id
  end

  test "rejects an invalid status", %{conn: conn, raw_token: raw, review: review} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/reviews/#{review.slug}/sections/0/decision", %{"status" => "maybe"})

    assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
    assert detail =~ "status"
  end
end
