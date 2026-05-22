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

  test "renders all four workflow chapters with demo CTAs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for {step, label} <- [
          {"push", "View section"},
          {"review", "Request changes"},
          {"reprompt", "Reprompt"},
          {"final", "Approve"}
        ] do
      assert has_element?(view, "#chapter-#{step}")

      assert has_element?(
               view,
               "#chapter-#{step} button[phx-click=\"set_demo_step\"][phx-value-step=\"#{step}\"]",
               label
             )
    end
  end

  test "demo CTAs advance the demo state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#home-demo[data-step=\"intro\"]")

    view
    |> element("#chapter-push button", "View section")
    |> render_click()

    assert has_element?(
             view,
             "#home-demo[data-step=\"push\"] .home-demo-section.is-section-1.is-expanded"
           )

    view
    |> element("#chapter-review button", "Request changes")
    |> render_click()

    assert has_element?(view, "#home-demo[data-step=\"review\"]")
    assert has_element?(view, ".home-demo-comment-row")

    view
    |> element("#chapter-reprompt button", "Reprompt")
    |> render_click()

    assert has_element?(view, "#home-demo[data-step=\"reprompt_prompt\"]")

    assert has_element?(
             view,
             "#chapter-reprompt .home-agent-input",
             "Address the comments on the review packet"
           )

    assert has_element?(view, "#chapter-reprompt .home-agent-send", "Send")

    view
    |> element("#chapter-reprompt .home-agent-send", "Send")
    |> render_click()

    assert has_element?(view, "#home-demo[data-step=\"reprompting\"]")

    assert has_element?(
             view,
             "#chapter-reprompt .home-agent-bubble",
             "Address the comments on the review packet"
           )

    assert has_element?(view, "#chapter-reprompt .home-agent-status", "Thinking...")

    send(view.pid, :complete_reprompt)
    render(view)

    assert has_element?(view, "#home-demo[data-step=\"reprompt\"]")
    assert has_element?(view, "#chapter-reprompt .home-agent-harness", "Pushed a new revision.")

    view
    |> element("#chapter-final button", "Approve")
    |> render_click()

    assert has_element?(
             view,
             "#home-demo[data-step=\"final\"] .home-demo-section.is-section-1.is-approved"
           )
  end

  test "ignores unknown demo steps", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "set_demo_step", %{"step" => "bogus"})
    assert has_element?(view, "#home-demo[data-step=\"intro\"]")
  end
end
