defmodule ReviewsWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Looks up the user pointed to by `:current_user_id` in the session and
  assigns it as `:current_user` on the conn. Assigns `nil` when there's no
  session — anonymous viewing is allowed.
  """
  import Plug.Conn

  alias Reviews.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :current_user_id)

    user =
      case user_id do
        nil -> nil
        id when is_integer(id) -> safe_get_user(id)
        _ -> nil
      end

    assign(conn, :current_user, user)
  end

  defp safe_get_user(id) do
    try do
      Accounts.get_user!(id)
    rescue
      Ecto.NoResultsError -> nil
    end
  end
end
