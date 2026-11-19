defmodule ReviewsWeb.Api.CodeSnapshotController do
  @moduledoc """
  CLI-facing code snapshot reservation endpoints.

  `POST /api/v1/code-snapshots` reserves a snapshot and returns a short-lived,
  ref-scoped upload credential. `POST /api/v1/code-snapshots/:id/complete`
  asks the provider to verify the uploaded refs against the reserved OIDs.

  Both return 404 with code `code_storage_disabled` when storage is off, which
  matches the "older server has no route" probe semantics.
  """
  use ReviewsWeb, :controller

  alias Reviews.CodeSnapshots
  alias Reviews.CodeStorage
  alias ReviewsWeb.ApiErrors

  @reserve_errors [
    :review_not_found,
    :unsupported_object_format,
    :snapshot_not_authorized,
    :invalid_oid,
    :invalid_head_kind
  ]

  @complete_errors [:snapshot_not_ready, :snapshot_not_authorized, :upload_expired, :ref_mismatch]

  @doc "POST /api/v1/code-snapshots"
  def create(conn, params) do
    with :ok <- check_enabled(),
         {:ok, result} <-
           CodeSnapshots.reserve(conn.assigns.current_principal, normalize_params(params)) do
      conn
      |> put_status(:created)
      |> json(render_reservation(result))
    else
      {:error, reason} when reason in [:code_storage_disabled | @reserve_errors] ->
        ApiErrors.render(conn, reason)

      # Provider failures (create repo, signing) never reach the client.
      {:error, _reason} ->
        ApiErrors.render(conn, :code_storage_unavailable)
    end
  end

  @doc "POST /api/v1/code-snapshots/:id/complete"
  def complete(conn, %{"id" => id}) do
    with :ok <- check_enabled(),
         {:ok, snapshot} <- CodeSnapshots.complete(conn.assigns.current_identity, id) do
      json(conn, %{
        id: snapshot.public_id,
        status: snapshot.status,
        base_oid: snapshot.base_oid,
        head_oid: snapshot.head_oid
      })
    else
      {:error, reason} when reason in [:code_storage_disabled | @complete_errors] ->
        ApiErrors.render(conn, reason)

      {:error, {:verify_failed, _reason}} ->
        ApiErrors.render(conn, :code_storage_unavailable)
    end
  end

  defp check_enabled do
    if CodeStorage.enabled?(), do: :ok, else: {:error, :code_storage_disabled}
  end

  defp normalize_params(params) do
    %{
      review_slug: params["review_slug"],
      object_format: params["object_format"],
      base_oid: params["base_oid"],
      head_oid: params["head_oid"],
      head_kind: params["head_kind"]
    }
  end

  defp render_reservation(%{snapshot: snapshot, repository: repository, upload: upload}) do
    %{
      id: snapshot.public_id,
      repository_id: repository.public_id,
      expires_at: snapshot.expires_at,
      upload: %{
        remote_url: upload.remote_url,
        token: upload.token,
        expires_at: upload.expires_at
      },
      refs: %{
        base: snapshot.base_ref,
        head: snapshot.head_ref
      }
    }
  end
end
