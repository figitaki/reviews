defmodule ReviewsWeb.HomeLiveTest do
  use ReviewsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "renders hero and install snippet", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "Review any diff."
    assert has_element?(view, "#hero-install-root")
    assert has_element?(view, "[data-install-cmd]")
    assert has_element?(view, "a[href$=\"github.com/figitaki/reviews\"]")
  end

  test "renders all four workflow chapters with demo triggers", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for step <- ~w(push review reprompt revise) do
      assert has_element?(view, "#chapter-#{step}[data-demo-step=\"#{step}\"]")
    end
  end

  test "set_demo_step advances the demo state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # initial state is :push
    assert has_element?(view, "#home-demo[data-step=\"push\"]")

    render_hook(view, "set_demo_step", %{"step" => "review"})
    assert has_element?(view, "#home-demo[data-step=\"review\"]")

    render_hook(view, "set_demo_step", %{"step" => "revise"})
    assert has_element?(view, "#home-demo[data-step=\"revise\"]")
  end

  test "ignores unknown demo steps", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "set_demo_step", %{"step" => "bogus"})
    assert has_element?(view, "#home-demo[data-step=\"push\"]")
  end
end
