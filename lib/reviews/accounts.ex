defmodule Reviews.Accounts do
  @moduledoc """
  The Accounts context.

  Owns users + API tokens. The web layer (controllers, LiveViews) should call
  into this module rather than touching `Reviews.Repo` directly.
  """
  import Ecto.Query, warn: false

  alias Reviews.Repo
  alias Reviews.Accounts.{ApiToken, User}

  ## Users

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_github_id(github_id) when is_integer(github_id) do
    Repo.get_by(User, github_id: github_id)
  end

  @doc """
  Upserts a user from a GitHub OAuth payload. Called from the
  `AuthController.callback/2` action.
  """
  def upsert_from_github(%{github_id: github_id} = attrs) when is_integer(github_id) do
    case get_user_by_github_id(github_id) do
      nil ->
        %User{}
        |> User.changeset(attrs)
        |> Repo.insert()

      %User{} = user ->
        user
        |> User.changeset(attrs)
        |> Repo.update()
    end
  end

  ## API tokens

  @token_prefix "rev_"
  @token_bytes 24

  @doc """
  Mints a new API token for `user`. Returns `{:ok, %ApiToken{}, raw_token}`.
  The raw token is shown ONCE at this point — only the hash is persisted.
  """
  def mint_token(%User{} = user, attrs \\ %{}) do
    raw = generate_raw_token()
    hash = hash_token(raw)

    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("token_hash", hash)
      |> Map.put("user_id", user.id)

    case %ApiToken{} |> ApiToken.changeset(attrs) |> Repo.insert() do
      {:ok, token} -> {:ok, token, raw}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Looks up the user for a raw bearer token. Returns `{:ok, user}` or
  `{:error, :invalid_token}`. Updates `last_used_at` on success.
  """
  def authenticate_token(raw) when is_binary(raw) do
    hash = hash_token(raw)

    query =
      from t in ApiToken,
        where: t.token_hash == ^hash,
        preload: [:user]

    case Repo.one(query) do
      nil ->
        {:error, :invalid_token}

      %ApiToken{user: user} = token ->
        _ = touch_last_used(token)
        {:ok, user}
    end
  end

  def authenticate_token(_), do: {:error, :invalid_token}

  def list_tokens_for(%User{id: user_id}) do
    Repo.all(from t in ApiToken, where: t.user_id == ^user_id, order_by: [desc: t.inserted_at])
  end

  defp touch_last_used(%ApiToken{} = token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    token |> Ecto.Changeset.change(last_used_at: now) |> Repo.update()
  end

  defp generate_raw_token do
    @token_prefix <>
      (:crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false))
  end

  defp hash_token(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw)
  end
end
