defmodule ReviewsWeb.StaleAssetsTest do
  # Not async: it sets the endpoint's static manifest, which every test reads.
  use ReviewsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @latest %{
    "assets/css/app.css" => "assets/css/app-new.css",
    "assets/js/app.js" => "assets/js/app-new.js"
  }

  setup do
    previous = ReviewsWeb.Endpoint.config(:cache_static_manifest_latest)
    Phoenix.Config.put(ReviewsWeb.Endpoint, :cache_static_manifest_latest, @latest)

    on_exit(fn ->
      Phoenix.Config.put(ReviewsWeb.Endpoint, :cache_static_manifest_latest, previous)
    end)
  end

  defp tracking(conn, statics), do: put_connect_params(conn, %{"_track_static" => statics})

  test "a tab with assets from an earlier deploy is asked to reload", %{conn: conn} do
    conn = tracking(conn, ["/assets/css/app-old.css", "/assets/js/app-old.js"])
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#assets-changed", "A new version of Reviews is available.")
    assert has_element?(view, "#assets-changed a[href='']", "reload")
  end

  test "the review page asks too", %{conn: conn} do
    author = Reviews.ReviewIndexFixtures.user!("stale-tab-author")

    {:ok, %{review: review}} =
      Reviews.Reviews.create_review_with_initial_patchset(author, %{
        title: "Stale tab",
        raw_diff: "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"
      })

    conn = tracking(conn, ["/assets/css/app-old.css?vsn=d"])
    {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}")

    assert has_element?(view, "#assets-changed")
  end

  test "a tab with the current assets is not asked", %{conn: conn} do
    conn = tracking(conn, ["/assets/css/app-new.css?vsn=d", "/assets/js/app-new.js?vsn=d"])
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#assets-changed")
  end

  test "dismissing the notice clears it", %{conn: conn} do
    conn = tracking(conn, ["/assets/css/app-old.css"])
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#assets-changed") |> render_click()

    refute has_element?(view, "#assets-changed")
  end
end
