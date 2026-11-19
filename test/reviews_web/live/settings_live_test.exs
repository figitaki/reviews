defmodule ReviewsWeb.SettingsLiveTest do
  use ReviewsWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Reviews.Accounts

  defp user! do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 44_001,
        username: "bill",
        email: "bill@example.com",
        avatar_url: nil
      })

    user
  end

  test "anonymous visitor sees a sign-in prompt", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#settings-page", "Account settings")
    assert has_element?(view, ".ds-empty-state", "Sign in to manage account settings")

    assert has_element?(
             view,
             ~s|.ds-empty-state a[href="/auth/github?return_to=/settings"]|,
             "Sign in with GitHub"
           )

    assert has_element?(view, ~s|.l-nav-signin[href="/auth/github?return_to=%2Fsettings"]|)
    refute has_element?(view, "#mint-token-form")
  end

  test "signed-in user sees appearance, identities, and access token sections", %{conn: conn} do
    user = user!()
    conn = Plug.Test.init_test_session(conn, %{current_user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#appearance")
    assert has_element?(view, "#identities")
    assert has_element?(view, "#access-tokens")
    assert has_element?(view, "#identity-human", "@bill")
    assert has_element?(view, "#token-identity-id")
    refute has_element?(view, "#tokens-list")
    assert has_element?(view, ".ds-settings-empty-inline", "No agent identities yet")
  end

  test "can revoke a token while keeping another token active", %{conn: conn} do
    user = user!()
    {:ok, other_token, other_raw} = Accounts.mint_token(user, %{name: "keep"})
    conn = Plug.Test.init_test_session(conn, %{current_user_id: user.id})
    {:ok, view, _html} = live(conn, ~p"/settings")

    view |> form("#mint-token-form", token: %{name: "revoke"}) |> render_submit()
    token = Enum.find(Accounts.list_tokens_for(user), &(&1.name == "revoke"))

    raw =
      view
      |> element("#new-token-banner code")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()

    assert {:ok, _} = Accounts.authenticate_token(raw)
    assert has_element?(view, "#revoke-token-#{token.id}[data-confirm]")
    view |> element("#revoke-token-#{token.id}") |> render_click()

    refute has_element?(view, "#token-#{token.id}")
    refute has_element?(view, "#new-token-banner")
    assert has_element?(view, "#token-#{other_token.id}")
    assert has_element?(view, "#identity-human", "1 token")
    assert {:error, :invalid_token} = Accounts.authenticate_token(raw)
    assert {:ok, _} = Accounts.authenticate_token(other_raw)

    view |> element("#revoke-token-#{other_token.id}") |> render_click()
    refute has_element?(view, "#tokens-list")
    assert has_element?(view, "#access-tokens .ds-empty-state", "No API tokens yet")
  end

  test "forged revoke events cannot delete another user's token", %{conn: conn} do
    owner = user!()
    {:ok, token, raw} = Accounts.mint_token(owner)
    {:ok, outsider} = Accounts.upsert_from_github(%{github_id: 44_002, username: "outsider"})
    conn = Plug.Test.init_test_session(conn, %{current_user_id: outsider.id})
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_click(view, "revoke_token", %{"id" => to_string(token.id)})
    assert has_element?(view, "#flash-error", "Token not found.")
    assert {:ok, _} = Accounts.authenticate_token(raw)
  end

  test "anonymous revoke events leave tokens active", %{conn: conn} do
    {:ok, token, raw} = Accounts.mint_token(user!())
    {:ok, view, _html} = live(conn, ~p"/settings")

    render_click(view, "revoke_token", %{"id" => to_string(token.id)})
    assert has_element?(view, "#flash-error", "Sign in to manage API tokens.")
    assert {:ok, _} = Accounts.authenticate_token(raw)
  end

  test "can create an agent identity and mint a token for it", %{conn: conn} do
    user = user!()
    conn = Plug.Test.init_test_session(conn, %{current_user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/settings")

    view
    |> form("#new-agent-identity-form",
      identity: %{display_name: "Codex", handle: "codex", provider: "Codex"}
    )
    |> render_submit()

    [agent] = Accounts.list_agent_identities_for(user)
    assert has_element?(view, "#identity-agent-#{agent.id}", "@codex")
    assert agent.provider == "Codex"

    assert agent.avatar_url ==
             ReviewsWeb.Endpoint.static_url() <> "/images/connectors/chatgpt.png"

    assert has_element?(view, ~s|#identity-agent-#{agent.id} img[src="#{agent.avatar_url}"]|)

    view
    |> form("#mint-token-form", token: %{identity_id: agent.id, name: "codex-local"})
    |> render_submit()

    assert has_element?(view, "#new-token-banner", "for Codex (@codex)")
    assert has_element?(view, "#tokens-list", "codex-local")
    assert has_element?(view, "#tokens-list", "Never used")

    refute render(view) =~ "token_hash"
  end

  test "a custom provider keeps its name, has no logo, and survives an error", %{conn: conn} do
    user = user!()
    {:ok, _} = Accounts.create_agent_identity(user, %{display_name: "Taken", handle: "taken"})
    conn = Plug.Test.init_test_session(conn, %{current_user_id: user.id})
    {:ok, view, _html} = live(conn, ~p"/settings")

    refute has_element?(view, "#agent-custom-provider")
    view |> form("#new-agent-identity-form", identity: %{provider: "custom"}) |> render_change()
    assert has_element?(view, "#agent-custom-provider")

    view
    |> form("#new-agent-identity-form",
      identity: %{display_name: "Hermes", handle: "taken", custom_provider: " Hermes "}
    )
    |> render_submit()

    assert has_element?(view, "#new-agent-identity-form", "has already been taken")
    assert has_element?(view, ~s|#agent-custom-provider[value=" Hermes "]|)

    view
    |> form("#new-agent-identity-form", identity: %{handle: "hermes"})
    |> render_submit()

    agent = Enum.find(Accounts.list_agent_identities_for(user), &(&1.handle == "hermes"))
    assert agent.provider == "Hermes"
    assert agent.avatar_url == nil
    assert has_element?(view, "#identity-agent-#{agent.id} .ds-avatar-mark", "H")
  end

  test "lists connected agents and disconnects one", %{conn: conn} do
    user = user!()

    {:ok, agent} =
      Accounts.create_agent_identity(user, %{display_name: "Claude", handle: "claude"})

    {:ok, link} =
      Gatekeep.Storage.Ecto.insert_grant([repo: Reviews.Repo], %{
        client_id: "https://agent.example/client.json",
        client_name: "Claude",
        subject: to_string(agent.id),
        owner: to_string(user.id),
        resource: "https://reviews.test/api/test",
        scopes: ["test:read"],
        grant_type: "authorization_code"
      })

    conn = Plug.Test.init_test_session(conn, %{current_user_id: user.id})
    {:ok, view, _html} = live(conn, ~p"/settings")

    assert has_element?(view, "#agent-link-#{link.id}", "agent.example")
    assert has_element?(view, "#agent-link-#{link.id}", "(not verified)")
    assert has_element?(view, "#agent-link-#{link.id}", "Claude (@claude)")

    view |> element("#revoke-agent-link-#{link.id}") |> render_click()

    assert has_element?(view, "#agent-link-#{link.id}", "Disconnected")
    refute has_element?(view, "#revoke-agent-link-#{link.id}")
    assert Reviews.Repo.get!(Reviews.OAuth.Grant, link.id).revoked_at
  end
end
