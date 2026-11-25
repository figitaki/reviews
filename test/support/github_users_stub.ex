defmodule Reviews.GitHubUsersStub do
  @moduledoc """
  Answers `Reviews.GitHubUsers` lookups in tests from a `%{login => github_id}`
  map, case-insensitively as GitHub does; any other login is a 404.
  """

  def stub(users) do
    Req.Test.stub(Reviews.GitHubUsers, fn conn ->
      login = conn.path_info |> List.last()

      case Enum.find(users, fn {name, _id} -> String.downcase(name) == String.downcase(login) end) do
        {name, id} -> Req.Test.json(conn, %{"id" => id, "login" => name})
        nil -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
      end
    end)
  end
end
