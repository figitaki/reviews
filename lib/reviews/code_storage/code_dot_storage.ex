defmodule Reviews.CodeStorage.CodeDotStorage do
  @moduledoc """
  code.storage (Pierre) adapter.

  The Reviews backend holds the organization's P-256 API private key and
  mints short-lived ES256 JWTs: broad-scope server tokens for its own API
  calls, and narrowly ref-scoped `git:write` tokens that the CLI uses to push
  exactly one snapshot's base and head refs.

  Config (under `config :reviews, Reviews.CodeStorage`):

    * `:org` — code.storage organization identifier
    * `:jwt_private_key` — P-256 private key, PKCS8 PEM
    * `:api_base_url` / `:git_base_url` — overrides for tests/self-hosting
    * `:req_options` — extra Req options (tests inject a Req.Test plug)

  Snapshot refs live in the default branch namespace
  (`refs/heads/snapshots/<snapshot_public_id>/{base,head}`); the upload
  token's ref policy allowlists those two branches and no-pushes everything
  else.

  `delete_snapshot/2` is deliberately a no-op: upload tokens cannot delete
  refs, and claimed refs live for the review's lifetime. Expired-but-claimed
  snapshot refs are reclaimed when the repository is deleted.
  """
  @behaviour Reviews.CodeStorage

  alias Reviews.CodeStorage.CodeDotStorage.{Client, Token}

  @impl true
  def create_repository(repository) do
    config = config()

    with :ok <- check_config(config),
         {:ok, token} <- Token.server_token(config[:org], repository.storage_key, key_pem(config)),
         {:ok, %{provider_repo_id: provider_repo_id}} <-
           Client.create_repo(config, token, repository.storage_key) do
      {:ok, %{storage_key: repository.storage_key, provider_repo_id: provider_repo_id}}
    end
  end

  @impl true
  def upload_instructions(repository, snapshot) do
    config = config()
    ttl = Reviews.CodeStorage.upload_token_ttl_seconds()

    with :ok <- check_config(config),
         {:ok, token} <-
           Token.upload_token(
             config[:org],
             repository.storage_key,
             snapshot.public_id,
             key_pem(config),
             ttl
           ) do
      {:ok,
       %{
         remote_url: "#{git_base_url(config)}/#{repository.storage_key}.git",
         token: token,
         expires_at: DateTime.add(DateTime.utc_now(), ttl)
       }}
    end
  end

  @impl true
  def verify(repository, snapshot) do
    config = config()

    with :ok <- check_config(config),
         {:ok, token} <- Token.server_token(config[:org], repository.storage_key, key_pem(config)),
         {:ok, %{sha: base_sha}} <-
           resolve_ref(config, token, repository, branch_name(snapshot.base_ref)),
         {:ok, %{sha: head_sha}} <-
           resolve_ref(config, token, repository, branch_name(snapshot.head_ref)) do
      if base_sha == snapshot.base_oid and head_sha == snapshot.head_oid do
        {:ok, %{base_oid: base_sha, head_oid: head_sha}}
      else
        {:error, :ref_mismatch}
      end
    else
      {:error, :not_found} -> {:error, :ref_mismatch}
      other -> other
    end
  end

  @impl true
  def delete_snapshot(_repository, _snapshot), do: :ok

  @impl true
  def delete_repository(repository) do
    config = config()

    with :ok <- check_config(config),
         {:ok, token} <- Token.server_token(config[:org], repository.storage_key, key_pem(config)) do
      Client.delete_repo(config, token, repository.storage_key)
    end
  end

  @impl true
  def checkout_source(_repository, _ref, _destination), do: {:error, :not_implemented}

  defp resolve_ref(config, token, repository, ref) do
    Client.get_commit(config, token, repository.storage_key, ref)
  end

  # Stored refs are full ("refs/heads/snapshots/<id>/base"); the commits
  # endpoint takes the short branch name.
  defp branch_name("refs/heads/" <> name), do: name
  defp branch_name(ref), do: ref

  defp git_base_url(config) do
    config[:git_base_url] || "https://#{config[:org]}.code.storage"
  end

  defp key_pem(config), do: config[:jwt_private_key]

  defp check_config(config) do
    if config[:org] && config[:jwt_private_key] do
      :ok
    else
      {:error, :code_storage_misconfigured}
    end
  end

  defp config do
    Application.get_env(:reviews, Reviews.CodeStorage, [])
  end
end
