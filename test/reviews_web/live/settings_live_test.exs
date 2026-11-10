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

    view
    |> form("#mint-token-form", token: %{identity_id: agent.id, name: "codex-local"})
    |> render_submit()

    assert has_element?(view, "#new-token-banner", "for Codex (@codex)")
    assert has_element?(view, "#tokens-list", "codex-local")
    assert has_element?(view, "#tokens-list", "Never used")

    refute render(view) =~ "token_hash"
  end
end
