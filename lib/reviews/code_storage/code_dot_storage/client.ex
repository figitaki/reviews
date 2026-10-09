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
  Create the repository named by the JWT `repo` claim. Idempotent: a 409
  (already exists — a retried reserve) resolves to the existing repository.
  """
  def create_repo(config, token, repo_path) do
    case request(config, token, :post, "/repos", json: %{}) do
      {:ok, %{status: status, body: body}} when status in [200, 201] ->
        {:ok, %{provider_repo_id: body["id"]}}

      {:ok, %{status: 409}} ->
        get_repo(config, token, repo_path)

      other ->
        request_error(other)
    end
  end

  def get_repo(config, token, repo_path) do
    case request(config, token, :get, "/repos/#{encode(repo_path)}", []) do
      {:ok, %{status: 200, body: body}} -> {:ok, %{provider_repo_id: body["id"]}}
      other -> request_error(other)
    end
  end

  @doc "Resolve a branch name, short SHA, or full SHA to a commit."
  def get_commit(config, token, repo_path, ref) do
    path = "/repos/#{encode(repo_path)}/commits/#{encode(ref)}"

    case request(config, token, :get, path, []) do
      {:ok, %{status: 200, body: body}} -> {:ok, %{sha: body["sha"]}}
      {:ok, %{status: 404}} -> {:error, :not_found}
      other -> request_error(other)
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

  defp request(config, token, method, path, opts) do
    [
      method: method,
      url: base_url(config) <> path,
      auth: {:bearer, token},
      retry: false
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
