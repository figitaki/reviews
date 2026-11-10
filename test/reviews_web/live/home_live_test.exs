defmodule ReviewsWeb.HomeLiveTest do
  use ReviewsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "landing page remains indexable", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200)
    assert get_resp_header(conn, "x-robots-tag") == []
  end

  test "robots policy discourages sensitive routes without blocking the landing page", %{
    conn: conn
  } do
    conn = get(conn, "/robots.txt")
    policy = response(conn, 200)
    assert policy =~ "User-agent: *"

    disallowed =
      for line <- String.split(policy, "\n"),
          String.starts_with?(line, "Disallow:"),
          do: line |> String.replace_prefix("Disallow:", "") |> String.trim()

    assert Enum.sort(disallowed) == ["/api/", "/auth/", "/dev/", "/r/", "/settings"]
    refute "/" in disallowed
    assert get_resp_header(conn, "x-robots-tag") == []
  end

  test "offers the real demo and installation instead of an embedded walkthrough", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-title", "Review any diff.")
    assert has_element?(view, "#home-demo-link[href='/r/demo-review']", "Open demo review")
    assert has_element?(view, "#reviews-home a[href='#home-install']")
    assert has_element?(view, "#hero-install-root [data-install-cmd]", "install.sh | sh")
    assert has_element?(view, "#hero-install-root button[data-install-copy]")
    assert has_element?(view, "#hero-install-root [role='status']")

    assert has_element?(
             view,
             "#home-docs-link[href='https://github.com/figitaki/reviews#readme']"
           )

    for id <- ["home-packet", "home-decisions", "home-revisions"] do
      assert has_element?(view, "##{id} h2")
    end

    refute has_element?(view, "#home-demo")
    refute has_element?(view, "[phx-click='set_demo_step']")
    refute has_element?(view, "a[href$='#chapter-push']")
  end

  test "demo link opens a seeded review anonymously", %{conn: conn} do
    Reviews.DemoReview.seed!()
    {:ok, view, _html} = live(conn, ~p"/")

    {:ok, demo, _html} =
      view
      |> element("#home-demo-link")
      |> render_click()
      |> follow_redirect(conn, ~p"/r/demo-review")

    assert has_element?(demo, "#review-packet-title", "Structured Markdown review packets")
  end
end
