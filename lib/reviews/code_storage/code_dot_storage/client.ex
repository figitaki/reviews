defmodule Reviews.CodeStorage.CodeDotStorage.Client do
  @moduledoc """
  Thin HTTP client for the code.storage API
  (`https://api.<org>.code.storage/api`). Repositories are addressed by their
  URL-encoded repo name (our `storage_key`, e.g. `reviews%2F<uuid>`).

  Callers pass a per-request bearer JWT; nothing here logs or returns the
  token. Tests inject `req_options: [plug: {Req.Test, ...}]` through the
  adapter config.
  """

  @doc """
  Create the repository named by the JWT `repo` claim. The provider returns
  201 for a new repository and 200 when it already exists. A 409 is a conflict.
  """
  def create_repo(config, token, _repo_path) do
    case request(config, token, :post, "/repos", json: %{}) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        repository_identity(body)

      other ->
        request_error(other)
    end
  end

  def get_repo(config, token, repo_path) do
    case request(config, token, :get, "/repos/#{encode(repo_path)}", []) do
      {:ok, %{status: 200, body: body}} -> repository_identity(body)
      other -> request_error(other)
    end
  end

  @doc "Resolve a branch name, short SHA, or full SHA to a commit."
  def get_commit(config, token, repo_path, ref) do
    path = "/repos/#{encode(repo_path)}/commit"

    case request(config, token, :get, path, params: [ref: ref]) do
      {:ok, %{status: 200, body: %{"commit" => %{"sha" => sha}}}}
      when is_binary(sha) ->
        case Regex.match?(~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/, sha) do
          true -> {:ok, %{sha: sha}}
          false -> {:error, :invalid_response}
        end

      {:ok, %{status: 200}} ->
        {:error, :invalid_response}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      other ->
        request_error(other)
    end
  end

  @doc "Permanently retire a repository. Idempotent on 404."
  def delete_repo(config, token, repo_path) do
    case request(config, token, :delete, "/repos/#{encode(repo_path)}", []) do
      {:ok, %{status: status}} when status in [200, 202, 204, 404] -> :ok
      other -> request_error(other)
    end
  end

  # Repo names contain a slash ("reviews/<uuid>") and must occupy a single
  # path segment.
  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  # repo_id remains a documented legacy field; current responses identify the
  # repository by repo_name. Neither create nor get documents an "id" field.
  defp repository_identity(%{"repo_id" => id}) when is_binary(id) and byte_size(id) > 0,
    do: {:ok, %{provider_repo_id: id}}

  defp repository_identity(%{"repo_name" => name}) when is_binary(name) and byte_size(name) > 0,
    do: {:ok, %{provider_repo_id: name}}

  defp repository_identity(_), do: {:error, :invalid_response}

  defp request(config, token, method, path, opts) do
    [
      method: method,
      url: base_url(config) <> path,
      auth: {:bearer, token},
      retry: false,
      redirect: false,
      # Reserve and complete run inside CLI requests; a slow provider must
      # fail fast so the push can fall back to diff-only.
      # Req 0.7 takes Finch pool and request options together under
      # `:finch`; it raises if `:finch` is combined with `:connect_options`.
      finch: [pool_timeout: 5_000, conn_opts: [transport_opts: [timeout: 5_000]]],
      receive_timeout: 15_000
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(config[:req_options] || [])
    |> Req.request()
  end

  defp base_url(config) do
    config[:api_base_url] || "https://api.#{config[:org]}.code.storage/api"
  end

  # Normalize failures without leaking auth material. Req exceptions and
  # response bodies could echo headers, so reduce to status/reason only.
  defp request_error({:ok, %{status: status}}), do: {:error, {:http_status, status}}

  defp request_error({:error, %{__exception__: true} = e}),
    do: {:error, {:transport, e.__struct__}}

  defp request_error({:error, reason}), do: {:error, {:transport, reason}}
end
