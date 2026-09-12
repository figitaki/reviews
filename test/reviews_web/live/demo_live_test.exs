defmodule ReviewsWeb.DemoLiveTest do
  use ReviewsWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  test "home links to hub and unseeded samples do not have broken links", %{conn: conn} do
    {:ok, home, _} = live(conn, ~p"/")
    assert has_element?(home, "#home-demo-link[href='/demo']")
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
      assert has_element?(review, "#revision-nav")
    end

    {:ok, markdown, _} = live(conn, ~p"/r/demo-markdown-v1")
    assert has_element?(markdown, "#review-packet")
    assert has_element?(markdown, "button[phx-click='toggle_hunk_diff']")
    assert has_element?(markdown, "[phx-hook='DiffRenderer'][data-file-path='docs/welcome.md']")
    markdown |> element("button[phx-click='toggle_hunk_diff']", "welcome.md") |> render_click()
    refute has_element?(markdown, "[phx-hook='DiffRenderer'][data-file-path='docs/welcome.md']")
    markdown |> element("button[phx-click='toggle_hunk_diff']", "welcome.md") |> render_click()
    assert has_element?(markdown, "[phx-hook='DiffRenderer'][data-file-path='docs/welcome.md']")
  end
end
