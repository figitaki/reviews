defmodule ReviewsWeb.ReviewListLiveTest do
  use ReviewsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Reviews.ReviewIndexFixtures

  alias ReviewsWeb.ReviewListLive

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{current_user_id: user.id})

  test "signed-out visitors get a sign-in prompt", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/reviews")

    assert has_element?(view, "#reviews-index .ds-empty-state", "Sign in to see your reviews")
    refute has_element?(view, "#review-filters")
    refute has_element?(view, "#nav-reviews")
  end

  test "signing in from the list returns to it, filters included", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/reviews?status=open")

    sign_in = ~p"/auth/github?#{[return_to: "/reviews?status=open"]}"
    assert has_element?(view, "#reviews-sign-in[href='#{sign_in}'] svg.ds-github-mark")
    assert has_element?(view, ".l-nav-signin[href='#{sign_in}']")
  end

  test "signed-in user sees their reviews and a nav link", %{conn: conn} do
    carey = user!("carey")
    conner = user!("conner")
    mine = review!(carey, "Speed up lookup", at: at(30))
    involved = review!(conner, "Billing export", at: at(10))
    comment!(involved, carey)
    hidden = review!(conner, "Not shared", at: at(5))

    {:ok, view, _html} = conn |> sign_in(carey) |> live(~p"/reviews")

    assert has_element?(view, "#nav-reviews[aria-current=page]")
    assert has_element?(view, "#review-#{mine.id} a[href='/r/#{mine.slug}']", "Speed up lookup")
    refute has_element?(view, "#review-#{mine.id}", "patchset")
    assert has_element?(view, "#review-#{involved.id} .rl-author", "@conner")
    assert has_element?(view, "#review-#{involved.id} .rl-badge-open", "1 open")
    refute has_element?(view, "#review-#{mine.id} .rl-badge-open")
    # Open threads leave a row unread; a row with nothing waiting is read.
    assert has_element?(view, "#review-#{mine.id}.is-read")
    refute has_element?(view, "#review-#{involved.id}.is-read")
    refute has_element?(view, "#review-#{hidden.id}")
    refute has_element?(view, "#review-pager")
  end

  test "filters patch the URL and narrow the list", %{conn: conn} do
    carey = user!("carey")
    conner = user!("conner")
    mine = review!(carey, "Speed up lookup", at: at(30))
    involved = review!(conner, "Billing export", at: at(10))
    comment!(involved, carey)

    {:ok, view, _html} = conn |> sign_in(carey) |> live(~p"/reviews")

    view |> element("#filter-status-open") |> render_click()
    assert_patch(view, ~p"/reviews?status=open")
    assert has_element?(view, "#filter-status-open[aria-current=true]")

    # Searching keeps the chip filters.
    view |> form("#review-filters", filters: %{q: "billing"}) |> render_change()
    assert_patch(view, ~p"/reviews?#{[q: "billing", status: "open"]}")
    assert has_element?(view, "#review-#{involved.id}")
    refute has_element?(view, "#review-#{mine.id}")

    # A second tap on the selected status chip turns it off.
    view |> element("#filter-status-open") |> render_click()
    assert_patch(view, ~p"/reviews?q=billing")

    view |> element("#clear-filters") |> render_click()
    assert_patch(view, ~p"/reviews")
    assert has_element?(view, "#review-#{mine.id}")
    refute has_element?(view, "#clear-filters")
  end

  test "an author's name filters by that author, and the chip removes it", %{conn: conn} do
    carey = user!("carey")
    conner = user!("conner")
    mine = review!(carey, "Speed up lookup", at: at(30))
    involved = review!(conner, "Billing export", at: at(10))
    comment!(involved, carey)

    {:ok, view, _html} = conn |> sign_in(carey) |> live(~p"/reviews?role=involved")

    view |> element("#review-#{involved.id} .rl-author") |> render_click()
    assert_patch(view, ~p"/reviews?#{[role: "involved", author: "conner"]}")
    assert has_element?(view, "#filter-author", "@conner")

    view |> element("#filter-author") |> render_click()
    assert_patch(view, ~p"/reviews?role=involved")
    refute has_element?(view, "#filter-author")
    refute has_element?(view, "#review-#{mine.id}")
  end

  test "URL params set the filters", %{conn: conn} do
    carey = user!("carey")
    conner = user!("conner")
    mine = review!(carey, "Speed up lookup", at: at(30))
    involved = review!(conner, "Billing export", at: at(10))
    comment!(involved, carey)

    {:ok, view, _html} = conn |> sign_in(carey) |> live(~p"/reviews?role=authored")

    assert has_element?(view, "#review-#{mine.id}")
    refute has_element?(view, "#review-#{involved.id}")
    assert has_element?(view, "#filter-role-authored[aria-current=true]")
    refute has_element?(view, "#filter-role-all[aria-current]")

    {:ok, view, _html} = conn |> sign_in(carey) |> live(~p"/reviews?role=nonsense")
    assert has_element?(view, "#review-#{involved.id}")
  end

  test "empty states", %{conn: conn} do
    carey = user!("carey")

    {:ok, view, _html} = conn |> sign_in(carey) |> live(~p"/reviews")
    assert has_element?(view, "#reviews-empty", "Nothing here yet")
    assert has_element?(view, "#empty-demo[href='/r/demo-review']")

    {:ok, view, _html} = conn |> sign_in(carey) |> live(~p"/reviews?q=zzz")
    assert has_element?(view, "#reviews-empty", "No reviews match")
    view |> element("#empty-clear") |> render_click()
    assert_patch(view, ~p"/reviews")
  end

  test "pages with Older and Newer links", %{conn: conn} do
    carey = user!("carey")
    reviews = for n <- 1..26, do: review!(carey, "Review #{n}", at: at(n))
    oldest = List.last(reviews)
    newest = List.first(reviews)

    {:ok, view, _html} = conn |> sign_in(carey) |> live(~p"/reviews")

    assert has_element?(view, "#review-#{newest.id}")
    refute has_element?(view, "#review-#{oldest.id}")
    refute has_element?(view, "#pager-newer")

    view |> element("#pager-older") |> render_click()
    assert_patch(view, ~p"/reviews?offset=25")
    assert has_element?(view, "#review-#{oldest.id}")
    refute has_element?(view, "#review-#{newest.id}")

    view |> element("#pager-newer") |> render_click()
    assert_patch(view, ~p"/reviews")
  end

  test "an offset past the end links back to the first page", %{conn: conn} do
    carey = user!("carey")
    review = review!(carey, "Only one")

    {:ok, view, _html} = conn |> sign_in(carey) |> live(~p"/reviews?offset=500")

    refute has_element?(view, "#review-#{review.id}")
    assert has_element?(view, "#reviews-empty", "No reviews on this page")
    refute has_element?(view, "#pager-range")

    view |> element("#pager-newer") |> render_click()
    assert_patch(view, ~p"/reviews")
    assert has_element?(view, "#review-#{review.id}")
  end

  test "relative_time/2" do
    now = ~U[2026-10-09 12:00:00Z]
    assert ReviewListLive.relative_time(~U[2026-10-09 11:59:30Z], now) == "just now"
    assert ReviewListLive.relative_time(~U[2026-10-09 11:15:00Z], now) == "45min ago"
    assert ReviewListLive.relative_time(~U[2026-10-09 07:00:00Z], now) == "5h ago"
    assert ReviewListLive.relative_time(~U[2026-10-06 12:00:00Z], now) == "3d ago"
    assert ReviewListLive.relative_time(~U[2026-01-01 12:00:00Z], now) == "2026-01-01"
  end
end
