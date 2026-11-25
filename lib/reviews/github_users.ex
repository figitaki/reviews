defmodule Reviews.GitHubUsers do
  @moduledoc """
  Looks up a GitHub account by login with GitHub's public
  `GET /users/{login}`, so named reviewers are stored by their numeric
  GitHub ID, which survives renames, rather than by login text.

  Tests inject `req_options: [plug: {Req.Test, Reviews.GitHubUsers}]` through
  `config :reviews, Reviews.GitHubUsers`.
  """

  # GitHub logins: letters, digits and single hyphens, at most 39 characters.
  @login ~r/^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$/

  @doc """
  Returns `{:ok, %{github_id: integer, login: String.t()}}` with the login as
  GitHub spells it, `{:error, :not_found}` for an unknown or malformed login,
  or `{:error, :unavailable}` when GitHub cannot be reached or refuses.
  """
  @spec lookup(String.t()) ::
          {:ok, %{github_id: integer(), login: String.t()}}
          | {:error, :not_found | :unavailable}
  def lookup(login) when is_binary(login) do
    login = login |> String.trim() |> String.trim_leading("@")

    if Regex.match?(@login, login), do: fetch(login), else: {:error, :not_found}
  end

  def lookup(_login), do: {:error, :not_found}

  defp fetch(login) do
    config = Application.get_env(:reviews, __MODULE__, [])

    [
      url: Keyword.get(config, :base_url, "https://api.github.com") <> "/users/" <> login,
      headers: [accept: "application/vnd.github+json", user_agent: "reviews"],
      retry: false,
      receive_timeout: 5_000
    ]
    |> Keyword.merge(Keyword.get(config, :req_options, []))
    |> Req.get()
    |> case do
      {:ok, %{status: 200, body: %{"id" => id, "login" => login}}} when is_integer(id) ->
        {:ok, %{github_id: id, login: login}}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      _ ->
        {:error, :unavailable}
    end
  end
end
