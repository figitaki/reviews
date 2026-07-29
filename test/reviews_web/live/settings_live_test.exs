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
