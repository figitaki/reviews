defmodule ReviewsWeb.DesignLiveTest do
  # Not async: one test turns the catalog off in the application env.
  use ReviewsWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "renders tokens and components in both themes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/design")

    assert has_element?(
             view,
             "#dc-pills [data-theme=dark] .ds-chip.is-selected[aria-current=true]"
           )

    assert has_element?(view, "#dc-pills [data-theme=light] .ds-chip:not(.is-selected)")
    assert has_element?(view, "#dc-buttons [data-theme=light] .ds-button.is-primary")
    # Token names come from tokens.css.
    assert has_element?(view, "#dc-colors .dc-name", "--ds-line-input")
    assert has_element?(view, "#dc-space .dc-name", "--radius-pill")
  end

  test "documents button and field states with the shared components", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/design")

    assert has_element?(view, "#dc-buttons [data-theme=dark] button.ds-button.is-ghost:disabled")
    # A ds_button with navigate is a link styled the same.
    assert has_element?(view, "#dc-buttons [data-theme=light] a.ds-button.is-primary[href]")
    # <.input> with errors marks the field and says what to do.
    assert has_element?(view, "#dc-field-error-dark.ds-input.is-error[aria-invalid=true]")
    assert has_element?(view, "#dc-fields [data-theme=dark] .ds-field-error", "Pick another")
  end

  test "lists the icons in use and the GitHub sign-in button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/design")

    assert has_element?(view, "#dc-icons [data-theme=dark] .dc-name", "hero-no-symbol")
    assert has_element?(view, "#dc-icons [data-theme=light] svg.ds-github-mark")

    assert has_element?(
             view,
             "#dc-icons [data-theme=dark] a.ds-button.is-primary svg.ds-github-mark"
           )

    assert has_element?(view, "#dc-icons [data-theme=dark] a.ds-button", "Sign in with GitHub")

    assert has_element?(view, "#dc-icons button.ds-button .ds-button-icon.hero-check")
  end

  test "the playground mounts sample threads and the floating buttons", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/design/components")

    threads =
      view
      |> element("#dcp-threads-light")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-threads")
      |> hd()
      |> JSON.decode!()

    assert Enum.map(threads, & &1["status"]) == ["open", "resolved", "open"]
    assert has_element?(view, "#dcp-phone-frame[src='/design/components/phone']")

    {:ok, phone, _html} = live(conn, ~p"/design/components/phone")
    assert has_element?(phone, "#review-activity .review-quick-button")
    # The decision sits in the content column, not the Guide rail.
    assert has_element?(
             phone,
             ".review-packet-shell.has-outline > .review-packet-grid #packet-section-0-decision"
           )

    # The Comments log asks the page to open a thread; the frame says which.
    render_hook(phone, "open_activity_thread", %{"thread_id" => "101"})
    assert has_element?(phone, "#dcp-opened", "thread 101")
  end

  test "the playground's diff and section decision answer like the review page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/design/components")
    path = ReviewsWeb.DesignFixtures.file_path()

    assert has_element?(view, "#dcp-shell .l-topbar")
    # Every signed-in top bar uses the same account menu.
    assert has_element?(view, "#dcp-shell .l-topbar .account-menu a[href='/settings']")
    assert has_element?(view, "#dcp-shell .ds-shell-actions .account-menu a[href='/auth/logout']")
    refute has_element?(view, "#dcp-shell .l-nav-signin svg")
    assert has_element?(view, "#dcp-hunk-diff[phx-hook=DiffRenderer]")
    # The sample patch adds five lines and removes two; the stat must agree.
    assert render(view) =~ "5 additions, 2 deletions"

    # A new line comment comes back as a fourth thread, without saving.
    render_hook(view, "create_comment", %{
      "file_path" => path,
      "side" => "new",
      "body" => "Why one retry?",
      "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 39}
    })

    assert_push_event(view, "threads_updated:" <> ^path, %{threads: threads})
    assert length(threads) == 4
    assert List.last(threads).comments |> hd() |> Map.fetch!(:body) == "Why one retry?"

    # A reply joins its thread.
    render_hook(view, "create_comment", %{"thread_id" => 103, "body" => "Agreed."})
    assert_push_event(view, "threads_updated:" <> ^path, %{threads: threads})
    assert length(Enum.find(threads, &(&1.id == 103)).comments) == 2

    render_hook(view, "toggle_hunk_diff", %{"hunk_id" => "dcp-hunk"})
    refute has_element?(view, "#dcp-hunk-summary.is-open")

    # Approving, then choosing Approve again, clears the decision.
    approve = "#packet-section-0-decision button.is-approved"
    view |> element(approve) |> render_click()
    assert has_element?(view, "#packet-section-0-decision.is-approved")
    view |> element(approve) |> render_click()
    assert has_element?(view, "#packet-section-0-decision.is-pending")
  end

  test "page layouts frame the real list, review and settings pages", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/design/layouts")

    for {id, src} <- [list: "/reviews", review: "/r/demo-review", settings: "/settings"],
        width <- ~w(desktop phone) do
      assert has_element?(view, "#dcl-#{id}-#{width}[src='#{src}']")
    end

    # Signed out, the list and Settings frames say they show the sign-in state.
    assert has_element?(view, "#dcl-list-state", "Signed out")
    assert has_element?(view, "#dcl-settings-state", "Signed out")
    refute has_element?(view, "#dcl-review-state")
  end

  test "returns 404 when the catalog is off", %{conn: conn} do
    Application.put_env(:reviews, :design_catalog, false)
    on_exit(fn -> Application.put_env(:reviews, :design_catalog, true) end)

    assert_error_sent 404, fn -> get(conn, ~p"/design") end
    assert_error_sent 404, fn -> get(conn, ~p"/design/components") end
    assert_error_sent 404, fn -> get(conn, ~p"/design/layouts") end
  end
end
