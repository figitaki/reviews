defmodule Reviews.AccountsTest do
  use Reviews.DataCase, async: true

  alias Reviews.Accounts
  alias Reviews.Accounts.Identity

  defp user!(username) do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: username,
        email: "#{username}@example.com",
        avatar_url: nil
      })

    user
  end

  test "GitHub upsert creates a human identity" do
    user = user!("carey")

    assert %Identity{} = identity = Accounts.human_identity_for(user)
    assert identity.kind == "human"
    assert identity.handle == "carey"
    assert identity.display_name == "carey"
    assert identity.owner_user_id == user.id
  end

  test "creates agent identities owned by a user" do
    user = user!("owner")

    assert {:ok, identity} =
             Accounts.create_agent_identity(user, %{
               "display_name" => "Claude",
               "handle" => "@claude",
               "provider" => "Claude"
             })

    assert identity.kind == "agent"
    assert identity.handle == "claude"
    assert identity.provider == "Claude"
    assert [^identity] = Accounts.list_agent_identities_for(user)
  end

  test "default tokens authenticate as the human identity" do
    user = user!("human")
    human_identity = Accounts.human_identity_for(user)

    assert {:ok, token, raw} = Accounts.mint_token(user, %{"name" => "laptop"})
    assert token.identity_id == human_identity.id

    assert {:ok, %{user: authed_user, identity: authed_identity}} =
             Accounts.authenticate_token(raw)

    assert authed_user.id == user.id
    assert authed_identity.id == human_identity.id
  end

  test "tokens can authenticate as an agent identity" do
    user = user!("bill")
    {:ok, agent} = Accounts.create_agent_identity(user, %{display_name: "Codex", handle: "codex"})

    assert {:ok, _token, raw} =
             Accounts.mint_token(user, %{"name" => "codex-local", "identity_id" => agent.id})

    assert {:ok, %{user: authed_user, identity: authed_identity}} =
             Accounts.authenticate_token(raw)

    assert authed_user.id == user.id
    assert authed_identity.id == agent.id
    assert authed_identity.handle == "codex"
  end

  test "rejects a token identity owned by another user" do
    owner = user!("owner")
    other_user = user!("other")

    {:ok, other_identity} =
      Accounts.create_agent_identity(other_user, %{display_name: "Codex", handle: "codex"})

    assert {:error, :invalid_identity} =
             Accounts.mint_token(owner, %{name: "not-owned", identity_id: other_identity.id})
  end

  test "keeps the human handle when a GitHub rename conflicts with an agent" do
    user = user!("old-handle")

    {:ok, _agent} =
      Accounts.create_agent_identity(user, %{display_name: "Agent", handle: "new-handle"})

    assert {:ok, updated_user} =
             Accounts.upsert_from_github(%{
               github_id: user.github_id,
               username: "new-handle",
               email: "renamed@example.com",
               avatar_url: "https://example.com/avatar.png"
             })

    assert updated_user.username == "new-handle"
    assert %Identity{} = human_identity = Accounts.human_identity_for(updated_user)
    assert human_identity.handle == "old-handle"
    assert human_identity.display_name == "new-handle"
    assert human_identity.avatar_url == "https://example.com/avatar.png"
  end

  test "rejects case-only duplicate handles for one owner" do
    user = user!("owner")

    assert {:ok, _identity} =
             Accounts.create_agent_identity(user, %{display_name: "Codex", handle: "Codex"})

    assert {:error, changeset} =
             Accounts.create_agent_identity(user, %{display_name: "codex", handle: "codex"})

    assert "has already been taken" in errors_on(changeset).handle
  end

  test "repeated first GitHub upserts are idempotent" do
    github_id = System.unique_integer([:positive])

    attrs = %{
      github_id: github_id,
      username: "idempotent",
      email: "idempotent@example.com",
      avatar_url: nil
    }

    assert {:ok, first_user} = Accounts.upsert_from_github(attrs)
    assert {:ok, second_user} = Accounts.upsert_from_github(attrs)
    assert first_user.id == second_user.id

    assert [%Identity{kind: "human", owner_user_id: owner_user_id}] =
             Accounts.list_identities_for(first_user)

    assert owner_user_id == first_user.id
  end
end
