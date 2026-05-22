defmodule Reviews.Accounts do
  @moduledoc """
  The Accounts context.

  Owns users + API tokens. The web layer (controllers, LiveViews) should call
  into this module rather than touching `Reviews.Repo` directly.
  """
  import Ecto.Query, warn: false

  alias Reviews.Repo
  alias Reviews.Accounts.{ApiToken, Identity, User}

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
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:user, User.changeset(%User{}, attrs))
        |> Ecto.Multi.run(:identity, fn _repo, %{user: user} -> ensure_human_identity(user) end)
        |> Repo.transaction()
        |> case do
          {:ok, %{user: user}} -> {:ok, user}
          {:error, _step, changeset, _} -> {:error, changeset}
        end

      %User{} = user ->
        Ecto.Multi.new()
        |> Ecto.Multi.update(:user, User.changeset(user, attrs))
        |> Ecto.Multi.run(:identity, fn _repo, %{user: user} -> ensure_human_identity(user) end)
        |> Repo.transaction()
        |> case do
          {:ok, %{user: user}} -> {:ok, user}
          {:error, _step, changeset, _} -> {:error, changeset}
        end
    end
  end

  ## Identities

  def get_identity!(id), do: Repo.get!(Identity, id)

  def human_identity_for(%User{id: user_id}) do
    Repo.get_by(Identity, owner_user_id: user_id, kind: "human")
  end

  def ensure_human_identity(%User{} = user) do
    case human_identity_for(user) do
      %Identity{} = identity ->
        identity
        |> Identity.changeset(%{
          handle: user.username,
          display_name: user.username,
          avatar_url: user.avatar_url
        })
        |> Repo.update()

      nil ->
        %Identity{}
        |> Identity.changeset(%{
          owner_user_id: user.id,
          kind: "human",
          handle: user.username,
          display_name: user.username,
          avatar_url: user.avatar_url,
          provider: "GitHub"
        })
        |> Repo.insert()
    end
  end

  def list_identities_for(%User{id: user_id}) do
    Identity
    |> where([i], i.owner_user_id == ^user_id)
    |> order_by([i],
      asc: fragment("CASE WHEN ? = 'human' THEN 0 ELSE 1 END", i.kind),
      asc: i.display_name
    )
    |> Repo.all()
  end

  def list_agent_identities_for(%User{id: user_id}) do
    Identity
    |> where([i], i.owner_user_id == ^user_id and i.kind == "agent")
    |> order_by([i], asc: i.display_name)
    |> Repo.all()
  end

  def create_agent_identity(%User{} = owner, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("owner_user_id", owner.id)
      |> Map.put("kind", "agent")

    %Identity{}
    |> Identity.changeset(attrs)
    |> Repo.insert()
  end

  def get_owned_identity(%User{id: user_id}, id) do
    Repo.get_by(Identity, id: id, owner_user_id: user_id)
  end

  def get_user_preference(%User{} = user, key, default \\ nil) do
    Map.get(user.preferences || %{}, to_string(key), default)
  end

  def put_user_preference(%User{} = user, key, value) do
    preferences = Map.put(user.preferences || %{}, to_string(key), value)

    user
    |> Ecto.Changeset.change(preferences: preferences)
    |> Repo.update()
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
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, identity} <- token_identity(user, attrs["identity_id"]) do
      attrs =
        attrs
        |> Map.put("token_hash", hash)
        |> Map.put("user_id", user.id)
        |> Map.put("identity_id", identity.id)

      case %ApiToken{} |> ApiToken.changeset(attrs) |> Repo.insert() do
        {:ok, token} -> {:ok, Repo.preload(token, :identity), raw}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @doc """
  Looks up the account + identity for a raw bearer token. Returns
  `{:ok, %{user: user, identity: identity}}` or
  `{:error, :invalid_token}`. Updates `last_used_at` on success.
  """
  def authenticate_token(raw) when is_binary(raw) do
    hash = hash_token(raw)

    query =
      from t in ApiToken,
        where: t.token_hash == ^hash,
        preload: [:user, :identity]

    case Repo.one(query) do
      nil ->
        {:error, :invalid_token}

      %ApiToken{user: user, identity: identity} = token ->
        _ = touch_last_used(token)
        {:ok, %{user: user, identity: identity}}
    end
  end

  def authenticate_token(_), do: {:error, :invalid_token}

  def list_tokens_for(%User{id: user_id}) do
    Repo.all(
      from t in ApiToken,
        where: t.user_id == ^user_id,
        order_by: [desc: t.inserted_at],
        preload: [:identity]
    )
  end

  def identity_token_counts(%User{id: user_id}) do
    ApiToken
    |> where([t], t.user_id == ^user_id)
    |> group_by([t], t.identity_id)
    |> select([t], {t.identity_id, count(t.id), max(t.last_used_at)})
    |> Repo.all()
    |> Map.new(fn {identity_id, count, last_used_at} ->
      {identity_id, %{count: count, last_used_at: last_used_at}}
    end)
  end

  defp touch_last_used(%ApiToken{} = token) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    token |> Ecto.Changeset.change(last_used_at: now) |> Repo.update()
  end

  defp token_identity(%User{} = user, nil) do
    case ensure_human_identity(user) do
      {:ok, identity} -> {:ok, identity}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp token_identity(%User{} = user, id) do
    case parse_id(id) do
      identity_id when is_integer(identity_id) ->
        case get_owned_identity(user, identity_id) do
          %Identity{} = identity -> {:ok, identity}
          nil -> {:error, :invalid_identity}
        end

      _ ->
        {:error, :invalid_identity}
    end
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  defp generate_raw_token do
    @token_prefix <>
      (:crypto.strong_rand_bytes(@token_bytes) |> Base.url_encode64(padding: false))
  end

  defp hash_token(raw) when is_binary(raw) do
    :crypto.hash(:sha256, raw)
  end
end
