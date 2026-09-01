defmodule Reviews.CodeStorage do
  @moduledoc """
  Provider-neutral boundary for storing review source snapshots as Git refs.

  Adapters implement this behaviour; the active adapter is selected at runtime
  from `config :reviews, Reviews.CodeStorage`. Phoenix code and (later) the LSP
  runner address repositories only through opaque `storage_key`s — they never
  construct provider paths themselves.

  Ships with `Reviews.CodeStorage.Disabled` (default) and
  `Reviews.CodeStorage.CodeDotStorage` (production, backed by code.storage).
  """

  alias Reviews.Reviews.{CodeRepository, CodeSnapshot}

  @type upload_instructions :: %{
          remote_url: String.t(),
          token: String.t(),
          expires_at: DateTime.t()
        }

  @doc "Create the provider-side repository for a staged code repository row."
  @callback create_repository(CodeRepository.t()) ::
              {:ok, %{storage_key: String.t(), provider_repo_id: String.t() | nil}}
              | {:error, term()}

  @doc """
  Return a short-lived upload target scoped to exactly the snapshot's two refs.
  The token must never be persisted or logged.
  """
  @callback upload_instructions(CodeRepository.t(), CodeSnapshot.t()) ::
              {:ok, upload_instructions()} | {:error, term()}

  @doc "Resolve both snapshot refs and return the commit OIDs they point at."
  @callback verify(CodeRepository.t(), CodeSnapshot.t()) ::
              {:ok, %{base_oid: String.t(), head_oid: String.t()}} | {:error, term()}

  @doc "Remove one snapshot's refs. Deferred for code.storage — see the adapter."
  @callback delete_snapshot(CodeRepository.t(), CodeSnapshot.t()) :: :ok | {:error, term()}

  @doc "Permanently remove the provider repository and all of its objects."
  @callback delete_repository(CodeRepository.t()) :: :ok | {:error, term()}

  @doc """
  Materialize a ref into `destination`. Reserved for the LSP runner (Phase 2+);
  both current adapters return `{:error, :not_implemented}`.
  """
  @callback checkout_source(CodeRepository.t(), ref :: String.t(), destination :: Path.t()) ::
              :ok | {:error, term()}

  ## Runtime configuration

  def adapter do
    config()[:adapter] || Reviews.CodeStorage.Disabled
  end

  def enabled? do
    adapter() != Reviews.CodeStorage.Disabled
  end

  @doc "Upload policy: `:optional` (warn and fall back to diff-only) or `:required`."
  def policy do
    config()[:policy] || :optional
  end

  def supported_object_formats do
    config()[:supported_object_formats] || ["sha1"]
  end

  def max_upload_bytes do
    config()[:max_upload_bytes] || 536_870_912
  end

  @doc "How long a reservation may stay unclaimed before the sweeper expires it."
  def snapshot_ttl_seconds do
    config()[:snapshot_ttl_seconds] || 900
  end

  def upload_token_ttl_seconds do
    config()[:upload_token_ttl_seconds] || 900
  end

  @doc "Payload for `GET /api/v1/capabilities`. Booleans and limits only."
  def capabilities do
    %{
      code_storage: %{
        enabled: enabled?(),
        required: policy() == :required,
        supported_object_formats: supported_object_formats(),
        max_upload_bytes: max_upload_bytes()
      },
      lsp: %{enabled: false, languages: []}
    }
  end

  defp config do
    Application.get_env(:reviews, __MODULE__, [])
  end
end
