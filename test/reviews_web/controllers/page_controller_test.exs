defmodule ReviewsWeb.PageControllerTest do
  use ReviewsWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Reviews Keeps Patchsets"
    assert html =~ "Open Sample Review"
  end
end
