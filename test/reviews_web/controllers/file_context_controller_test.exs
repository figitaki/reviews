defmodule ReviewsWeb.FileContextControllerTest do
  use ReviewsWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import ExUnit.CaptureLog

  alias Reviews.Accounts
  alias Reviews.Reviews, as: ReviewsContext

  setup do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: "context-reader",
        email: nil,
        avatar_url: nil
      })

    {:ok, _token, token} = Accounts.mint_token(user, %{name: "context"})
    header = "diff --git a/x.js b/x.js\n--- a/x.js\n+++ b/x.js\n"

    raw =
      header <>
        "@@ -27,7 +27,7 @@\n line 27\n line 28\n line 29\n-line 30\n+changed\n line 31\n line 32\n line 33\n"

    context =
      header <>
        "@@ -1,60 +1,60 @@\n" <>
        Enum.map_join(1..60, fn
          30 -> "-line 30\n+changed\n"
          i -> " line #{i}\n"
        end)

    %{user: user, token: token, raw: raw, context: context}
  end

  defp upload(token, attrs) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> post(~p"/api/v1/reviews", Map.merge(%{"title" => "Context"}, attrs))
  end

  defp signed_in(user), do: init_test_session(build_conn(), current_user_id: user.id)

  test "uploads context separately, reads lazily with sign-in, and audits the read", data do
    %{"slug" => slug} =
      upload(data.token, %{"raw_diff" => data.raw, "context_diff" => data.context})
      |> json_response(201)

    review = ReviewsContext.get_review_by_slug!(slug)
    patchset = ReviewsContext.latest_patchset(review)
    [file] = ReviewsContext.list_files(patchset)
    path = ~p"/r/#{slug}/patchsets/1/files/#{file.id}/context"

    assert get(build_conn(), path) |> json_response(401)
    public = get(build_conn(), ~p"/api/v1/reviews/#{slug}") |> json_response(200)
    refute inspect(public) =~ "line 1\\n"
    {:ok, view, _} = live(signed_in(data.user), ~p"/r/#{slug}/changes")
    assert has_element?(view, "[data-context-url='#{path}']")
    refute render(view) =~ "line 1\n"

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log([level: :info], fn ->
        response =
          signed_in(data.user) |> put_req_header("accept", "application/json") |> get(path)

        assert get_resp_header(response, "cache-control") == ["no-store"]
        assert %{"old" => old, "new" => new} = json_response(response, 200)
        assert String.starts_with?(old, "line 1\n")
        assert new =~ "changed\n"
      end)

    assert log =~ "file_context_read"
    assert log =~ "\"identity_id\""
    assert log =~ "\"review_id\":#{review.id}"
    assert log =~ "\"file_id\":#{file.id}"
    assert log =~ "\"bytes\""
    refute log =~ "changed"

    assert get(signed_in(data.user), ~p"/r/#{slug}/patchsets/2/files/#{file.id}/context")
           |> json_response(404)

    assert get(signed_in(data.user), ~p"/r/unknown/patchsets/1/files/#{file.id}/context")
           |> json_response(404)
  end

  test "rejects mismatched source and changes without creating a review", data do
    for context <- [
          String.replace(data.context, "+changed", "+different"),
          String.replace(data.context, " line 29\n", " different\n")
        ] do
      response = upload(data.token, %{"raw_diff" => data.raw, "context_diff" => context})
      assert %{"errors" => %{"context_diff" => [_]}} = json_response(response, 422)
    end
  end

  test "context preserves insertion boundaries and missing final newlines", data do
    header = "diff --git a/x.js b/x.js\n--- a/x.js\n+++ b/x.js\n"

    for {raw, context, old, new} <- [
          {"@@ -1,0 +2 @@\n+inserted\n", "@@ -1,2 +1,3 @@\n one\n+inserted\n two\n", "one\ntwo\n",
           "one\ninserted\ntwo\n"},
          {"@@ -2 +2 @@\n-old\n+new\n\\ No newline at end of file\n",
           "@@ -1,2 +1,2 @@\n one\n-old\n+new\n\\ No newline at end of file\n", "one\nold\n",
           "one\nnew"}
        ] do
      %{"slug" => slug} =
        upload(data.token, %{"raw_diff" => header <> raw, "context_diff" => header <> context})
        |> json_response(201)

      review = ReviewsContext.get_review_by_slug!(slug)
      [file] = review |> ReviewsContext.latest_patchset() |> ReviewsContext.list_files()
      response = get(signed_in(data.user), ~p"/r/#{slug}/patchsets/1/files/#{file.id}/context")
      assert json_response(response, 200) == %{"old" => old, "new" => new}
    end
  end

  test "partial packet slices use correct coordinates and have no context loader", data do
    packet = %{
      "title" => "Slice",
      "sections" => [
        %{
          "title" => "Change",
          "rows" => [
            %{
              "kind" => "hunk",
              "path" => "x.js",
              "hunk_index" => 1,
              "line_start" => 4,
              "line_end" => 5
            },
            %{
              "kind" => "hunk",
              "path" => "x.js",
              "hunk_index" => 1,
              "line_start" => 1,
              "line_end" => 3
            },
            %{
              "kind" => "hunk",
              "path" => "x.js",
              "hunk_index" => 1,
              "line_start" => 6,
              "line_end" => 8
            }
          ]
        }
      ]
    }

    %{"slug" => slug} =
      upload(data.token, %{
        "raw_diff" => data.raw,
        "context_diff" => data.context,
        "packet" => packet
      })
      |> json_response(201)

    {:ok, view, _} = live(signed_in(data.user), ~p"/r/#{slug}")
    render_click(view, "select_guide_section", %{"section_index" => "0"})
    assert has_element?(view, "[data-raw-diff*='@@ -30,1 +30,1 @@']")
    refute has_element?(view, "[data-context-url]")
  end

  test "diff-only uploads stay readable, and context reads are rate limited", data do
    %{"slug" => slug} = upload(data.token, %{"raw_diff" => data.raw}) |> json_response(201)
    review = ReviewsContext.get_review_by_slug!(slug)
    [file] = review |> ReviewsContext.latest_patchset() |> ReviewsContext.list_files()
    path = ~p"/r/#{slug}/patchsets/1/files/#{file.id}/context"
    for _ <- 1..30, do: assert(get(signed_in(data.user), path) |> json_response(404))
    response = get(signed_in(data.user), path)
    assert json_response(response, 429)
    assert get_resp_header(response, "retry-after") == ["60"]
  end
end
