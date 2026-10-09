defmodule Reviews.CodeStorage.Errors do
  @moduledoc """
  Stable, provider-neutral error codes for the code-storage protocol. These
  codes go on the wire as `errors.code` so the CLI can branch on them without
  parsing message text.
  """

  @codes ~w(
    code_storage_disabled
    unsupported_object_format
    repository_too_large
    upload_expired
    ref_mismatch
    snapshot_not_ready
    snapshot_not_authorized
  )a

  def codes, do: @codes

  def valid?(code), do: code in @codes

  def message(:code_storage_disabled), do: "code storage is not enabled on this server"
  def message(:unsupported_object_format), do: "the repository object format is not supported"
  def message(:repository_too_large), do: "the repository exceeds the upload size limit"
  def message(:upload_expired), do: "the snapshot reservation expired before it was claimed"
  def message(:ref_mismatch), do: "the uploaded refs do not match the reserved object ids"
  def message(:snapshot_not_ready), do: "the code snapshot is not ready to be claimed"
  def message(:snapshot_not_authorized), do: "the code snapshot was reserved by another identity"

  def http_status(:code_storage_disabled), do: :not_found
  def http_status(:snapshot_not_authorized), do: :forbidden
  def http_status(:upload_expired), do: :gone
  def http_status(_code), do: :unprocessable_entity
end
