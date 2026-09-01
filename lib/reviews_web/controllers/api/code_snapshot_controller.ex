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

  import ReviewsWeb.Api.ApiHelpers

  alias Reviews.CodeSnapshots
  alias Reviews.CodeStorage
  alias Reviews.CodeStorage.Errors

  @doc "POST /api/v1/code-snapshots"
  def create(conn, params) do
    identity = conn.assigns.current_identity

    with :ok <- check_enabled(),
         {:ok, result} <- CodeSnapshots.reserve(identity, normalize_params(params)) do
      conn
      |> put_status(:created)
      |> json(render_reservation(result))
    else
      {:error, :code_storage_disabled} ->
        disabled(conn)

      {:error, :review_not_found} ->
        error_json(conn, :not_found, "Review not found")

      {:error, :unsupported_object_format} ->
        error_json(
          conn,
          :unprocessable_entity,
          :unsupported_object_format,
          Errors.message(:unsupported_object_format)
        )

      {:error, code} when code in [:invalid_oid, :invalid_head_kind] ->
        error_json(conn, :unprocessable_entity, "Invalid snapshot parameters")

      {:error, :upload_failed} ->
        error_json(conn, :bad_gateway, "code storage unavailable")

      {:error, _reason} ->
        error_json(conn, :bad_gateway, "code storage unavailable")
    end
  end

  @doc "POST /api/v1/code-snapshots/:id/complete"
  def complete(conn, %{"id" => id}) do
    identity = conn.assigns.current_identity

    with :ok <- check_enabled(),
         {:ok, snapshot} <- CodeSnapshots.complete(identity, id) do
      json(conn, %{
        id: snapshot.public_id,
        status: snapshot.status,
        base_oid: snapshot.base_oid,
        head_oid: snapshot.head_oid
      })
    else
      {:error, :code_storage_disabled} ->
        disabled(conn)

      {:error, code}
      when code in [:snapshot_not_ready, :snapshot_not_authorized, :upload_expired, :ref_mismatch] ->
        error_json(conn, Errors.http_status(code), code, Errors.message(code))

      {:error, {:verify_failed, _reason}} ->
        error_json(conn, :bad_gateway, "code storage unavailable")
    end
  end

  defp check_enabled do
    if CodeStorage.enabled?(), do: :ok, else: {:error, :code_storage_disabled}
  end

  defp disabled(conn) do
    error_json(
      conn,
      Errors.http_status(:code_storage_disabled),
      :code_storage_disabled,
      Errors.message(:code_storage_disabled)
    )
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
