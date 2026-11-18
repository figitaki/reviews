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

  test "returns 404 when the catalog is off", %{conn: conn} do
    Application.put_env(:reviews, :design_catalog, false)
    on_exit(fn -> Application.put_env(:reviews, :design_catalog, true) end)

    assert_error_sent 404, fn -> get(conn, ~p"/design") end
  end
end
