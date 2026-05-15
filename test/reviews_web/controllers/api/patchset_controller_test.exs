defmodule ReviewsWeb.Api.PatchsetControllerTest do
  use ReviewsWeb.ConnCase, async: true

  alias Reviews.Accounts
  alias Reviews.Reviews

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

    %{review: review, raw_token: raw}
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
