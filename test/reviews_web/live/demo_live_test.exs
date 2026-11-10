defmodule ReviewsWeb.DemoLiveTest do
  use ReviewsWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "home links to the real demo, and the hub lists the unseeded samples without links", %{
    conn: conn
  } do
    {:ok, home, _} = live(conn, ~p"/")
    assert has_element?(home, "#home-demo-link[href='/r/#{Reviews.DemoReview.slug()}']")
    {:ok, hub, _} = live(conn, ~p"/demo")
    assert has_element?(hub, "#demo-hub")
    refute has_element?(hub, "#demo-open-markdown")
    assert has_element?(hub, "#demo-check-theme")
  end

  test "every seeded sample opens anonymously with its real review controls", %{conn: conn} do
    {:ok, author} = Reviews.Accounts.upsert_from_github(%{github_id: 91235, username: "hub-test"})
    Reviews.DemoCatalog.seed!(author)
    {:ok, hub, _} = live(conn, ~p"/demo")

    for scenario <- Reviews.DemoCatalog.scenarios() do
      assert has_element?(hub, "#demo-open-#{scenario.id}[href='/r/#{scenario.slug}']")
      {:ok, review, _} = live(conn, ~p"/r/#{scenario.slug}")
      assert has_element?(review, "#review-toolbar")
    end

    {:ok, markdown, _} = live(conn, ~p"/r/demo-markdown-v1")
    assert has_element?(markdown, "#review-packet")
    {:ok, changes, _} = live(conn, ~p"/r/demo-markdown-v1/changes")
    assert has_element?(changes, "[phx-hook='DiffRenderer'][data-file-path='docs/welcome.md']")
  end
end
