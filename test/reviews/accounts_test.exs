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
end
