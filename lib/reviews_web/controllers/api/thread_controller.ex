defmodule ReviewsWeb.Api.ThreadController do
  @moduledoc """
  CLI-facing thread status endpoint.
  """
  use ReviewsWeb, :controller

  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads

  @doc "PATCH /api/v1/reviews/:slug/threads/:thread_id"
  def update(conn, %{"slug" => slug, "thread_id" => thread_id, "status" => status}) do
    identity = conn.assigns.current_identity

    case ReviewsContext.get_review_by_slug(slug) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{errors: %{detail: "Review not found"}})

      review ->
        case Threads.update_status(review, thread_id, identity, status) do
          {:ok, thread} ->
            json(conn, %{
              id: thread.id,
              status: thread.status,
              resolved_by: identity_payload(thread.resolved_by),
              resolved_at: encode_dt(thread.resolved_at)
            })

          {:error, :not_found} ->
            conn
            |> put_status(:not_found)
            |> json(%{errors: %{detail: "Thread not found"}})

          {:error, :invalid_status} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: %{detail: "status must be \"open\" or \"resolved\""}})

          {:error, _reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: %{detail: "could not update thread"}})
        end
    end
  end

  def update(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: "status is required"}})
  end

  defp identity_payload(identity) when not is_nil(identity) do
    %{
      id: identity.id,
      kind: identity.kind,
      handle: identity.handle,
      username: identity.handle,
      display_name: identity.display_name,
      avatar_url: identity.avatar_url
    }
  end

  defp identity_payload(_), do: nil

  defp encode_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_dt(_), do: nil
end
