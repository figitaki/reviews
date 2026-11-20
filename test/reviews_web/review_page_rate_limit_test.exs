defmodule ReviewsWeb.ReviewPageRateLimitTest do
  # Not async: it changes the limit's application config.
  use ReviewsWeb.ConnCase, async: false

  alias Reviews.Accounts
  alias Reviews.Reviews, as: ReviewsCtx
  alias ReviewsWeb.Plugs.ReviewPageRateLimit

  @limit 3

  setup do
    previous = Application.get_env(:reviews, ReviewPageRateLimit)
    Application.put_env(:reviews, ReviewPageRateLimit, Keyword.put(previous, :limit, @limit))
    ReviewPageRateLimit.reset()

    on_exit(fn ->
      Application.put_env(:reviews, ReviewPageRateLimit, previous)
      ReviewPageRateLimit.reset()
    end)

    {:ok, author} =
      Accounts.upsert_from_github(%{
        github_id: 9_265_000 + System.unique_integer([:positive]),
        username: "limit-author",
        email: "limit@example.com",
        avatar_url: nil
      })

    {:ok, %{review: review}} =
      ReviewsCtx.create_review_with_initial_patchset(author, %{
        title: "Rate limited change",
        description: "Make bar do :new",
        raw_diff: "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"
      })

    %{author: author, review: review}
  end

  defp from(ip), do: %{build_conn() | remote_ip: ip}

  test "anonymous requests over the limit get 429 with retry-after", %{review: review} do
    ip = {203, 0, 113, 1}

    for path <- [~p"/r/#{review.slug}", ~p"/r/#{review.slug}/changes", ~p"/r/#{review.slug}"] do
      assert from(ip) |> get(path) |> html_response(200)
    end

    conn = from(ip) |> get(~p"/r/#{review.slug}/changes")

    assert conn.status == 429
    assert [retry_after] = get_resp_header(conn, "retry-after")
    assert String.to_integer(retry_after) in 1..60
    assert response_content_type(conn, :text) =~ "text/plain"
    assert conn.resp_body =~ "Too many requests"
  end

  test "a crawler under the limit still gets the link-preview tags", %{review: review} do
    conn =
      from({203, 0, 113, 2})
      |> put_req_header(
        "user-agent",
        "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)"
      )
      |> get(~p"/r/#{review.slug}")

    page = conn |> html_response(200) |> LazyHTML.from_document()

    content = fn property ->
      page |> LazyHTML.query(~s(meta[property="#{property}"])) |> LazyHTML.attribute("content")
    end

    assert content.("og:title") == ["Rate limited change"]
    assert content.("og:description") == ["Make bar do :new"]
  end

  test "a signed-in user is not limited", %{review: review, author: author} do
    for _ <- 1..(@limit + 2) do
      conn =
        from({203, 0, 113, 3})
        |> Plug.Test.init_test_session(%{current_user_id: author.id})
        |> get(~p"/r/#{review.slug}")

      assert html_response(conn, 200)
    end
  end

  test "the limit is per client IP", %{review: review} do
    for _ <- 1..(@limit + 1), do: from({203, 0, 113, 4}) |> get(~p"/r/#{review.slug}")
    assert from({203, 0, 113, 4}) |> get(~p"/r/#{review.slug}") |> Map.get(:status) == 429

    assert from({203, 0, 113, 5}) |> get(~p"/r/#{review.slug}") |> html_response(200)
  end

  test "other routes are not limited", %{review: review} do
    for _ <- 1..(@limit + 2), do: from({203, 0, 113, 6}) |> get(~p"/r/#{review.slug}")

    assert from({203, 0, 113, 6}) |> get(~p"/") |> html_response(200)

    assert from({203, 0, 113, 6})
           |> put_req_header("accept", "application/json")
           |> get(~p"/api/v1/reviews/#{review.slug}")
           |> json_response(200)
  end

  describe "counter table" do
    @config [limit: 2, window_seconds: 60, max_entries: 3, client_ip: :remote_ip]

    test "a new window starts a new count" do
      assert ReviewPageRateLimit.hit(:a, 120, @config) == :ok
      assert ReviewPageRateLimit.hit(:a, 130, @config) == :ok
      assert ReviewPageRateLimit.hit(:a, 170, @config) == {:error, 10}
      assert ReviewPageRateLimit.hit(:a, 180, @config) == :ok
    end

    test "the sweep drops windows that have ended" do
      :ok = ReviewPageRateLimit.hit(:a, 120, @config)
      :ok = ReviewPageRateLimit.hit(:b, 180, @config)

      assert ReviewPageRateLimit.sweep(180) == 1
      assert ReviewPageRateLimit.hit(:b, 181, @config) == :ok
      assert ReviewPageRateLimit.hit(:b, 182, @config) == {:error, 58}
    end

    test "past the entry cap, new clients share the overflow bucket" do
      for ip <- [:a, :b, :c], do: :ok = ReviewPageRateLimit.hit(ip, 120, @config)

      # The table is full: :d and :e share one count; :a keeps its own.
      assert ReviewPageRateLimit.hit(:d, 120, @config) == :ok
      assert ReviewPageRateLimit.hit(:e, 120, @config) == :ok
      assert ReviewPageRateLimit.hit(:d, 120, @config) == {:error, 60}
      assert ReviewPageRateLimit.hit(:a, 120, @config) == :ok

      # Once the sweep frees the table, new clients get their own counts again.
      ReviewPageRateLimit.sweep(180)
      assert ReviewPageRateLimit.hit(:d, 180, @config) == :ok
      assert ReviewPageRateLimit.hit(:d, 180, @config) == :ok
    end
  end
end
