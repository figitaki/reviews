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

    conn =
      authenticated_json_conn(raw)
      |> post(~p"/api/v1/reviews/#{review.slug}/sections/0/decision", %{
        "status" => "approved"
      })

    assert %{"section_index" => 0, "status" => nil} = json_response(conn, 200)
    assert [] = PacketSectionDecisions.list_for_review(review, agent)
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

  test "reports an unknown section index accurately", %{raw_token: raw, review: review} do
    conn =
      authenticated_json_conn(raw)
      |> post(~p"/api/v1/reviews/#{review.slug}/sections/9/decision", %{"status" => "approved"})

    assert %{"errors" => %{"detail" => "Section not found"}} = json_response(conn, 404)
  end

  test "rejects malformed section indexes", %{raw_token: raw, review: review} do
    conn =
      authenticated_json_conn(raw)
      |> post(~p"/api/v1/reviews/#{review.slug}/sections/5abc/decision", %{
        "status" => "approved"
      })

    assert %{"errors" => %{"detail" => "Invalid section index"}} = json_response(conn, 400)
  end

  defp authenticated_json_conn(raw) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end
end
