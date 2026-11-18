defmodule ReviewsWeb.ErrorHTMLTest do
  use ReviewsWeb.ConnCase, async: true

  # Bring render_to_string/4 for testing custom views
  import Phoenix.Template, only: [render_to_string: 4]

  test "renders 404.html with a link home" do
    page =
      ReviewsWeb.ErrorHTML
      |> render_to_string("404", "html", [])
      |> LazyHTML.from_fragment()

    assert page |> LazyHTML.query("#not-found") |> LazyHTML.text() =~ "Page not found"
    assert page |> LazyHTML.query("#not-found-home") |> LazyHTML.attribute("href") == ["/"]
  end

  test "an unknown path returns the 404 page", %{conn: conn} do
    page = conn |> get("/nope") |> html_response(404) |> LazyHTML.from_document()
    assert page |> LazyHTML.query("#not-found") |> LazyHTML.text() =~ "Page not found"
    assert page |> LazyHTML.query("#not-found-home") |> LazyHTML.attribute("href") == ["/"]
  end

  test "renders 500.html" do
    assert render_to_string(ReviewsWeb.ErrorHTML, "500", "html", []) == "Internal Server Error"
  end
end
