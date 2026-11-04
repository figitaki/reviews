defmodule ReviewsWeb.Api.PatchsetControllerTest do
  use ReviewsWeb.ConnCase, async: true

  alias Reviews.Accounts
  alias Reviews.Reviews

  @diff "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+newer\n"

  setup do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 98_765,
        username: "carey",
        email: "carey@example.com",
        avatar_url: nil
      })

    {:ok, _token, raw} = Accounts.mint_token(user, %{"name" => "test"})

    {:ok, %{review: review}} =
      Reviews.create_review_with_initial_patchset(user, %{
        title: "Add foo",
        base_sha: "deadbeef",
        branch_name: "carey/foo",
        raw_diff: "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"
      })

    %{user: user, review: review, raw_token: raw}
  end

  test "rejects an unrelated account without adding a revision", %{conn: conn, review: review} do
    {:ok, outsider} =
      Accounts.upsert_from_github(%{
        github_id: 98_766,
        username: "outsider",
        email: "outsider@example.com",
        avatar_url: nil
      })

    {:ok, _token, raw} = Accounts.mint_token(outsider, %{name: "outsider"})
    patchsets = Reviews.list_patchsets(review)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> post(~p"/api/v1/reviews/#{review.slug}/patchsets", %{raw_diff: @diff})

    assert %{"errors" => %{"detail" => "Forbidden"}} = json_response(conn, 403)
    assert Reviews.list_patchsets(review) == patchsets
  end

  test "rejects unauthenticated uploads without adding a revision", %{conn: conn, review: review} do
    patchsets = Reviews.list_patchsets(review)
    conn = post(conn, ~p"/api/v1/reviews/#{review.slug}/patchsets", %{raw_diff: @diff})

    assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    assert Reviews.list_patchsets(review) == patchsets
  end

  test "allows a same-owner agent to update a human-authored review", %{
    conn: conn,
    user: user,
    review: review
  } do
    {:ok, agent} = Accounts.create_agent_identity(user, %{handle: "agent", display_name: "Agent"})
    {:ok, _token, raw} = Accounts.mint_token(user, %{name: "agent", identity_id: agent.id})

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> post(~p"/api/v1/reviews/#{review.slug}/patchsets", %{raw_diff: @diff})

    assert %{"patchset_number" => 2} = json_response(conn, 201)
    assert Reviews.latest_patchset(review).raw_diff == @diff
  end

  test "allows the human owner and a sibling agent to update an agent-authored review", %{
    user: user,
    raw_token: human_raw
  } do
    {:ok, author} =
      Accounts.create_agent_identity(user, %{handle: "author", display_name: "Author"})

    {:ok, sibling} =
      Accounts.create_agent_identity(user, %{handle: "sibling", display_name: "Sibling"})

    {:ok, _token, agent_raw} =
      Accounts.mint_token(user, %{name: "agent", identity_id: sibling.id})

    {:ok, %{review: review}} =
      Reviews.create_review_with_initial_patchset(author, %{
        title: "Agent review",
        raw_diff: @diff
      })

    for {raw, number} <- [{human_raw, 2}, {agent_raw, 3}] do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> post(~p"/api/v1/reviews/#{review.slug}/patchsets", %{raw_diff: @diff})

      assert %{"patchset_number" => ^number} = json_response(conn, 201)
      assert Reviews.latest_patchset(review).number == number
    end
  end

  test "stores optional packet JSON on appended patchsets", %{
    conn: conn,
    review: review,
    raw_token: raw
  } do
    packet = %{
      "format_version" => 1,
      "title" => "Patchset v2 guide",
      "tasks" => [%{"key" => "smoke", "description" => "Smoke test it"}]
    }

    body = %{
      "base_sha" => "cafef00d",
      "branch_name" => "carey/foo",
      "raw_diff" => "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+newer\n",
      "packet" => packet
    }

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/reviews/#{review.slug}/patchsets", body)

    assert %{"patchset_number" => 2} = json_response(conn, 201)

    conn = get(build_conn(), ~p"/api/v1/reviews/#{review.slug}")
    assert get_in(json_response(conn, 200), ["selected_patchset", "packet"]) == packet
  end
end
