defmodule ReviewsWeb.FileContextController do
  use ReviewsWeb, :controller
  require Logger

  alias Reviews.RateLimiter
  alias Reviews.Reviews, as: ReviewsContext

  def show(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with %{id: user_id} <- conn.assigns.current_user,
         :ok <- RateLimiter.check(:context, user_id, 30),
         {number, ""} when number > 0 and number <= 2_147_483_647 <-
           Integer.parse(params["number"]),
         {file_id, ""} when file_id > 0 and file_id <= 9_223_372_036_854_775_807 <-
           Integer.parse(params["file_id"]),
         {:file, %{context: %{"old" => old, "new" => new}} = file} <-
           {:file, ReviewsContext.get_file_context(params["slug"], number, file_id)} do
      Logger.info(
        JSON.encode!(%{
          event: "file_context_read",
          user_id: user_id,
          identity_id: Reviews.Accounts.human_identity_for(conn.assigns.current_user).id,
          review_id: file.review_id,
          patchset_number: number,
          file_id: file_id,
          bytes: byte_size(old) + byte_size(new)
        })
      )

      json(conn, %{old: old, new: new})
    else
      nil -> conn |> put_status(:unauthorized) |> json(%{error: "Sign in to expand context."})
      :limited -> ReviewsWeb.Plugs.RequestBudget.reject(conn)
      _ -> conn |> put_status(:not_found) |> json(%{error: "No uploaded context for this file."})
    end
  end
end
