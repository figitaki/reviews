defmodule ReviewsWeb.Api.ReviewControllerTest do
  use ReviewsWeb.ConnCase, async: true

  alias Reviews.Accounts
  alias Reviews.Reviews, as: ReviewsContext

  describe "POST /api/v1/reviews" do
    setup do
      {:ok, user} =
        Accounts.upsert_from_github(%{
          github_id: 12_345,
          username: "carey",
          email: "carey@example.com",
          avatar_url: nil
        })

      {:ok, _token, raw} = Accounts.mint_token(user, %{"name" => "test"})

      {:ok, agent} =
        Accounts.create_agent_identity(user, %{display_name: "Codex", handle: "codex"})

      {:ok, _agent_token, agent_raw} =
        Accounts.mint_token(user, %{name: "agent", identity_id: agent.id})

      %{user: user, raw_token: raw, agent: agent, agent_raw_token: agent_raw}
    end

    test "creates a review + patchset with a valid token", %{conn: conn, raw_token: raw} do
      body = %{
        "title" => "Make user lookup faster",
        "description" => "A short description.",
        "base_sha" => "deadbeef",
        "branch_name" => "carey/perf",
        "raw_diff" => "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews", body)

      assert %{
               "id" => _,
               "slug" => slug,
               "url" => url,
               "patchset_number" => 1
             } = json_response(conn, 201)

      assert is_binary(slug) and slug != ""
      assert url =~ slug
    end

    test "stores the token identity as review author", %{
      conn: conn,
      agent: agent,
      agent_raw_token: raw
    } do
      body = %{
        "title" => "Agent-authored review",
        "description" => "",
        "base_sha" => "deadbeef",
        "branch_name" => "codex/perf",
        "raw_diff" => "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews", body)

      %{"slug" => slug} = json_response(conn, 201)
      review = ReviewsContext.get_review_by_slug(slug)
      assert review.author_id == agent.id
    end

    test "stores optional packet JSON on the initial patchset", %{conn: conn, raw_token: raw} do
      packet = %{
        "format_version" => 1,
        "title" => "Reviewer guide",
        "summary" => "Read this first.",
        "tour" => [%{"kind" => "hunk", "path" => "foo"}]
      }

      body = %{
        "title" => "Make user lookup faster",
        "base_sha" => "deadbeef",
        "branch_name" => "carey/perf",
        "raw_diff" => "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n",
        "packet" => packet
      }

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews", body)

      %{"slug" => slug} = json_response(conn, 201)

      conn = get(build_conn(), ~p"/api/v1/reviews/#{slug}")
      assert get_in(json_response(conn, 200), ["selected_patchset", "packet"]) == packet
    end

    test "rejects requests with no bearer token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews", %{"title" => "x"})

      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "rejects requests with a bad token", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer not-a-real-token")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/reviews", %{"title" => "x"})

      assert json_response(conn, 401)
    end
  end

  describe "GET /api/v1/reviews/:slug" do
    setup do
      {:ok, user} =
        Accounts.upsert_from_github(%{
          github_id: 54_321,
          username: "carey",
          email: "carey@example.com",
          avatar_url: nil
        })

      diff_v1 =
        "diff --git a/foo b/foo\n" <>
          "--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"

      {:ok, %{review: review, patchset: ps1}} =
        ReviewsContext.create_review_with_initial_patchset(user, %{
          title: "Add foo",
          description: "Test review",
          base_sha: "deadbeef",
          branch_name: "carey/foo",
          raw_diff: diff_v1,
          packet: %{
            "format_version" => 1,
            "title" => "Packet v1",
            "summary" => "Initial packet."
          }
        })

      diff_v2 =
        "diff --git a/foo b/foo\n" <>
          "--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+newer\n"

      {:ok, ps2} =
        ReviewsContext.append_patchset(review, %{
          base_sha: "cafef00d",
          branch_name: "carey/foo",
          raw_diff: diff_v2
        })

      %{review: review, ps1: ps1, ps2: ps2, user: user}
    end

    test "returns review JSON anonymously (latest patchset by default)",
         %{conn: conn, review: review, ps2: ps2} do
      conn = get(conn, ~p"/api/v1/reviews/#{review.slug}")
      body = json_response(conn, 200)

      assert body["slug"] == review.slug
      assert body["title"] == "Add foo"
      assert body["url"] =~ review.slug
      assert length(body["patchsets"]) == 2

      assert [
               %{
                 "number" => 1,
                 "packet_present" => true,
                 "stats" => %{"files" => 1, "additions" => 1, "deletions" => 1}
               },
               %{
                 "number" => 2,
                 "packet_present" => false,
                 "stats" => %{"files" => 1, "additions" => 1, "deletions" => 1}
               }
             ] = body["patchsets"]

      selected = body["selected_patchset"]
      assert selected["number"] == ps2.number
      assert selected["packet"] == nil
      assert selected["stats"] == %{"files" => 1, "additions" => 1, "deletions" => 1}
      assert is_list(selected["files"])
      assert length(selected["files"]) == 1

      [file] = selected["files"]
      assert file["path"] == "foo"
      assert file["status"] == "modified"
      assert file["raw_diff"] =~ "+newer"
    end

    test "supports ?patchset=N to fetch a specific patchset",
         %{conn: conn, review: review, ps1: ps1} do
      conn = get(conn, ~p"/api/v1/reviews/#{review.slug}?patchset=#{ps1.number}")
      body = json_response(conn, 200)

      assert body["selected_patchset"]["number"] == ps1.number
      assert body["selected_patchset"]["packet"]["title"] == "Packet v1"
      [file] = body["selected_patchset"]["files"]
      assert file["raw_diff"] =~ "+new\n"
      refute file["raw_diff"] =~ "newer"
    end

    test "returns 404 for an unknown slug", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/reviews/does-not-exist")
      assert %{"errors" => %{"detail" => "Review not found"}} = json_response(conn, 404)
    end

    test "returns 404 for an unknown patchset number",
         %{conn: conn, review: review} do
      conn = get(conn, ~p"/api/v1/reviews/#{review.slug}?patchset=99")
      assert %{"errors" => %{"detail" => "Patchset not found"}} = json_response(conn, 404)
    end
  end

  describe "GET /api/v1/reviews" do
    import Reviews.ReviewIndexFixtures

    setup do
      carey = user!("carey-list")
      conner = user!("conner-list")
      agent = agent!(carey, "codex")

      {:ok, _token, human_raw} = Accounts.mint_token(carey, %{"name" => "laptop"})

      {:ok, _token, agent_raw} =
        Accounts.mint_token(carey, %{"name" => "agent", "identity_id" => agent.id})

      mine = review!(carey, "Speed up lookup", at: at(30))
      by_agent = review!(agent, "Agent cleanup", at: at(20))
      involved = review!(conner, "Billing export", at: at(10))
      comment!(involved, carey)
      _hidden = review!(conner, "Not shared with carey", at: at(5))

      %{
        human_raw: human_raw,
        agent_raw: agent_raw,
        mine: mine,
        by_agent: by_agent,
        involved: involved
      }
    end

    defp list(conn, raw, params \\ %{}) do
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> get(~p"/api/v1/reviews", params)
    end

    test "requires a token", %{conn: conn} do
      assert conn |> get(~p"/api/v1/reviews") |> json_response(401)
    end

    test "human token lists reviews for all of the owner's identities", ctx do
      body = ctx.conn |> list(ctx.human_raw) |> json_response(200)

      assert Enum.map(body["reviews"], & &1["slug"]) == [
               ctx.involved.slug,
               ctx.by_agent.slug,
               ctx.mine.slug
             ]

      assert body["limit"] == 25
      assert body["offset"] == 0
      assert body["next_offset"] == nil

      [involved | _] = body["reviews"]
      assert involved["role"] == "involved"
      assert involved["title"] == "Billing export"
      assert involved["url"] =~ "/r/#{ctx.involved.slug}"
      assert involved["author"]["handle"] == "conner-list"
      assert involved["patchset_count"] == 1
      assert involved["latest_patchset_number"] == 1
      assert involved["thread_count"] == 1
      assert involved["open_thread_count"] == 1
      assert involved["has_new_patchset"] == false
      assert is_binary(involved["updated_at"])
    end

    test "agent token lists only the agent's reviews", ctx do
      body = ctx.conn |> list(ctx.agent_raw) |> json_response(200)
      assert Enum.map(body["reviews"], & &1["slug"]) == [ctx.by_agent.slug]
    end

    test "filters and pagination", ctx do
      body = ctx.conn |> list(ctx.human_raw, %{"role" => "authored"}) |> json_response(200)
      assert Enum.map(body["reviews"], & &1["slug"]) == [ctx.by_agent.slug, ctx.mine.slug]

      body = ctx.conn |> list(ctx.human_raw, %{"author" => "codex"}) |> json_response(200)
      assert Enum.map(body["reviews"], & &1["slug"]) == [ctx.by_agent.slug]

      body = ctx.conn |> list(ctx.human_raw, %{"q" => "lookup"}) |> json_response(200)
      assert Enum.map(body["reviews"], & &1["slug"]) == [ctx.mine.slug]

      body = ctx.conn |> list(ctx.human_raw, %{"status" => "open"}) |> json_response(200)
      assert Enum.map(body["reviews"], & &1["slug"]) == [ctx.involved.slug]

      body = ctx.conn |> list(ctx.human_raw, %{"limit" => "2"}) |> json_response(200)
      assert length(body["reviews"]) == 2
      assert body["next_offset"] == 2

      body =
        ctx.conn |> list(ctx.human_raw, %{"limit" => "2", "offset" => "2"}) |> json_response(200)

      assert Enum.map(body["reviews"], & &1["slug"]) == [ctx.mine.slug]
      assert body["next_offset"] == nil
    end

    test "bad filter values return 400 with a message per param", ctx do
      body =
        ctx.conn
        |> list(ctx.human_raw, %{"role" => "boss", "limit" => "0"})
        |> json_response(400)

      assert body["errors"]["role"] =~ "must be one of"
      assert body["errors"]["limit"] == "must be 1 or more"
    end
  end
end
