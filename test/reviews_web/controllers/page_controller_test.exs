defmodule ReviewsWeb.PageControllerTest do
  use ReviewsWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Reviews Turns Any Git Diff"
    assert html =~ "Open Demo Review"
  end
end
