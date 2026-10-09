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
    assert has_element?(view, "#review-#{mine.id}", "You wrote it")
    assert has_element?(view, "#review-#{involved.id}", "@conner")
    assert has_element?(view, "#review-#{involved.id}", "1 open")
    assert has_element?(view, "#review-#{involved.id}", "1 thread")
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

    view
    |> form("#review-filters", filters: %{q: "billing", role: "all", status: "all", author: ""})
    |> render_change()

    assert_patch(view, ~p"/reviews?q=billing")
    assert has_element?(view, "#review-#{involved.id}")
    refute has_element?(view, "#review-#{mine.id}")
    assert has_element?(view, "#clear-filters")

    view |> element("#clear-filters") |> render_click()
    assert_patch(view, ~p"/reviews")
    assert has_element?(view, "#review-#{mine.id}")
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
    assert has_element?(view, "#filter-role option[value=authored][selected]")

    {:ok, view, _html} = conn |> sign_in(carey) |> live(~p"/reviews?role=nonsense")
    assert has_element?(view, "#review-#{involved.id}")
  end

  test "empty states", %{conn: conn} do
    carey = user!("carey")

    {:ok, view, _html} = conn |> sign_in(carey) |> live(~p"/reviews")
    assert has_element?(view, ".ds-empty-state", "No reviews yet")

    {:ok, view, _html} = conn |> sign_in(carey) |> live(~p"/reviews?q=zzz")
    assert has_element?(view, ".ds-empty-state", "No reviews match")
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

  test "relative_time/2" do
    now = ~U[2026-10-09 12:00:00Z]
    assert ReviewListLive.relative_time(~U[2026-10-09 11:59:30Z], now) == "just now"
    assert ReviewListLive.relative_time(~U[2026-10-09 11:15:00Z], now) == "45 min ago"
    assert ReviewListLive.relative_time(~U[2026-10-09 07:00:00Z], now) == "5 h ago"
    assert ReviewListLive.relative_time(~U[2026-10-06 12:00:00Z], now) == "3 d ago"
    assert ReviewListLive.relative_time(~U[2026-01-01 12:00:00Z], now) == "2026-01-01"
  end
end
