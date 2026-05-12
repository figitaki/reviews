defmodule ReviewsWeb.PageController do
  use ReviewsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
