defmodule ReviewsWeb.DeviceLoginTest do
  @moduledoc """
  `reviews login` over HTTP: the device authorization grant for the CLI's
  client, the `/device` page, CLI tokens at `/api/v1`, and the rules that
  keep human-identity tokens to the CLI.
  """
  use ReviewsWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Gatekeep.DeviceAuthorization
  alias Gatekeep.Storage.Ecto.DeviceCode
  alias Reviews.Accounts
  alias Reviews.OAuth
  alias Reviews.OAuth.DeviceAttempts
  alias Reviews.OAuthTestClient.Fetcher
  alias Reviews.Repo

  @grant "urn:ietf:params:oauth:grant-type:device_code"
  @cli_api "https://reviews.test/api/v1"

  setup do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: "carey-#{System.unique_integer([:positive])}"
      })

    {:ok, human} = Accounts.ensure_human_identity(user)
    on_exit(fn -> DeviceAttempts.reset(user.id) end)
    %{user: user, human: human}
  end

  defp start(params) do
    build_conn()
    |> post(~p"/oauth/device_authorization", Map.merge(%{"client_id" => "reviews-cli"}, params))
  end

  defp start!(params \\ %{}),
    do: start(Map.merge(%{"resource" => @cli_api}, params)) |> json_response(200)

  defp poll(device_code, client_id \\ "reviews-cli") do
    build_conn()
    |> post(~p"/oauth/token", %{
      "grant_type" => @grant,
      "client_id" => client_id,
      "device_code" => device_code
    })
  end

  # As if the CLI's last poll were a minute ago.
  defp wait, do: Repo.update_all(DeviceCode, set: [last_polled_at: ~U[2020-01-01 00:00:00Z]])

  defp signed_in(user), do: build_conn() |> init_test_session(current_user_id: user.id)

  defp me(access_token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> access_token)
    |> get(~p"/api/v1/me")
  end

  defp error(conn), do: {conn.status, json_response(conn, conn.status)["error"]}

  test "the CLI signs in, as the human identity by default", %{user: user, human: human} do
    %{"device_code" => device_code, "user_code" => user_code} = body = start!()
    assert body["verification_uri"] == "https://reviews.test/device"
    assert body["interval"] == 5

    assert error(poll(device_code)) == {400, "authorization_pending"}
    assert error(poll(device_code)) == {400, "slow_down"}

    # Signed out, the link asks for sign-in and comes back with the code.
    html = build_conn() |> get(~p"/device?#{[user_code: user_code]}") |> html_response(200)
    assert html =~ ~s(id="device-sign-in")
    assert html =~ ~s(id="device-sign-in-legal")
    assert html =~ URI.encode_www_form("/device?user_code=" <> user_code)

    # Signed in, the link shows the code to check; it approves nothing.
    html = user |> signed_in() |> get(~p"/device?#{[user_code: user_code]}") |> html_response(200)
    assert html =~ ~s(id="device-confirm-code")
    assert html =~ ~s(id="device-confirm-legal")
    assert html =~ user_code
    # The countdown starts near the code's 10 minutes.
    [_, left] = Regex.run(~r/id="device-confirm-expiry"[^>]*data-seconds-left="(\d+)"/, html)
    assert String.to_integer(left) in 590..600
    wait()
    assert error(poll(device_code)) == {400, "authorization_pending"}

    # The entry form has a box per letter, accepting only the code's letters.
    html = user |> signed_in() |> get(~p"/device") |> html_response(200)
    assert html =~ ~s(data-alphabet="BCDFGHJKLMNPQRSTVWXZ")
    assert length(Regex.scan(~r/id="device-user-code-\d"/, html)) == 8
    assert html =~ "Codes expire 10 minutes after"

    # Typed into the boxes, the way people type it.
    typed = user_code |> String.downcase() |> String.replace("-", "") |> String.graphemes()
    html = user |> signed_in() |> post(~p"/device", %{"user_code" => typed}) |> html_response(200)
    assert html =~ ~s(id="device-confirm-form")
    # The picker offers the human identity first, chosen by default.
    assert html =~ ~r/<input[^>]*checked[^>]*id="device-identity-#{human.id}"/

    html =
      user
      |> signed_in()
      |> post(~p"/device/decide", %{
        "user_code" => user_code,
        "decision" => "approve",
        "identity_id" => to_string(human.id)
      })
      |> html_response(200)

    assert html =~ ~s(id="device-approved")

    wait()
    tokens = poll(device_code) |> json_response(200)
    assert tokens["token_type"] == "Bearer"
    assert tokens["scope"] == "cli"

    me = tokens["access_token"] |> me() |> json_response(200)
    assert me["username"] == user.username
    assert me["identity"]["id"] == human.id
    assert me["identity"]["kind"] == "human"

    # The refresh token rotates.
    refreshed =
      build_conn()
      |> post(~p"/oauth/token", %{
        "grant_type" => "refresh_token",
        "client_id" => "reviews-cli",
        "refresh_token" => tokens["refresh_token"]
      })
      |> json_response(200)

    assert refreshed["refresh_token"] != tokens["refresh_token"]
    assert refreshed["access_token"] |> me() |> json_response(200)

    # Settings revokes the sign-in: its tokens stop at once.
    [%{id: grant_id, subject: subject}] = OAuth.list_grants_for(user)
    assert subject == to_string(human.id)
    assert :ok = OAuth.revoke_grant(user, grant_id)

    conn = me(refreshed["access_token"])
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Bearer error="invalid_token")]
  end

  describe "creating an agent during device approval" do
    defp new_agent_post(user, code, attrs, decision \\ "approve") do
      user
      |> signed_in()
      |> post(~p"/device/decide", %{
        "user_code" => code,
        "decision" => decision,
        "identity_id" => "new",
        "new_identity" => attrs
      })
    end

    test "offers creation without changing the human default and issues agent tokens", %{
      user: user
    } do
      %{"device_code" => device, "user_code" => code} = start!()
      html = user |> signed_in() |> get(~p"/device?#{[user_code: code]}") |> html_response(200)
      assert html =~ ~s(id="device-identity-new")
      assert Accounts.list_agent_identities_for(user) == []

      html =
        new_agent_post(user, code, %{
          "display_name" => "My helper",
          "handle" => "helper",
          "owner_user_id" => "-1",
          "kind" => "human",
          "provider" => "forged"
        })
        |> html_response(200)

      assert html =~ ~s(id="device-approved")
      [agent] = Accounts.list_agent_identities_for(user)
      assert agent.owner_user_id == user.id
      assert agent.kind == "agent"
      assert agent.provider == nil
      tokens = poll(device) |> json_response(200)
      assert tokens["scope"] == "cli"
      assert (tokens["access_token"] |> me() |> json_response(200))["identity"]["id"] == agent.id

      # A repeated form submission must not leave a second identity behind.
      assert new_agent_post(user, code, %{"display_name" => "Duplicate", "handle" => "second"}).status ==
               400

      assert [^agent] = Accounts.list_agent_identities_for(user)
    end

    test "invalid fields preserve the new choice and values, and allow correction", %{user: user} do
      %{"device_code" => device, "user_code" => code} = start!()

      for handle <- ["", "bad handle"] do
        html =
          new_agent_post(user, code, %{"display_name" => "My helper", "handle" => handle})
          |> html_response(200)

        assert html =~ ~r/<input[^>]*checked[^>]*id="device-identity-new"/
        assert html =~ ~s(value="My helper")
        assert Accounts.list_agent_identities_for(user) == []
        assert {:ok, _} = OAuth.lookup_device(code)
      end

      assert new_agent_post(user, code, %{"display_name" => "My helper", "handle" => "valid"}).status ==
               200

      assert poll(device).status == 200
    end

    test "malformed fields are validation errors, not crashes", %{user: user} do
      %{"user_code" => code} = start!()

      for attrs <- [nil, "not a map", [], %{"display_name" => [], "handle" => %{}}] do
        html = new_agent_post(user, code, attrs) |> html_response(200)
        assert html =~ ~s(id="device-new-identity")
        assert Accounts.list_agent_identities_for(user) == []
        assert {:ok, _} = OAuth.lookup_device(code)
      end
    end

    test "failure after identity insertion rolls it back", %{user: user} do
      %{"user_code" => code} = start!()
      # Lookup succeeds, but Gatekeep refuses an approval with no scopes.
      Repo.update_all(DeviceCode, set: [scopes: []])
      assert {:ok, _} = OAuth.lookup_device(code)

      assert {:error, :invalid_user_code} =
               OAuth.approve_device_new_agent(user, code, %{
                 "display_name" => "Helper",
                 "handle" => "rollback"
               })

      assert Accounts.list_agent_identities_for(user) == []
      assert {:ok, _} = OAuth.lookup_device(code)
    end

    test "a taken handle stays pending and leaves existing agents untouched", %{user: user} do
      {:ok, agent} =
        Accounts.create_agent_identity(user, %{"display_name" => "Existing", "handle" => "taken"})

      %{"user_code" => code} = start!()

      html =
        new_agent_post(user, code, %{"display_name" => "New helper", "handle" => "TAKEN"})
        |> html_response(200)

      assert html =~ "has already been taken"
      assert [^agent] = Accounts.list_agent_identities_for(user)
      assert {:ok, _} = OAuth.lookup_device(code)
    end

    test "deny, expired, signed-out and rate-limited requests create nothing", %{user: user} do
      attrs = %{"display_name" => "Helper", "handle" => "helper"}
      %{"user_code" => code} = start!()
      assert new_agent_post(user, code, attrs, "deny").status == 200
      assert Accounts.list_agent_identities_for(user) == []
      %{"user_code" => code} = start!()

      html =
        build_conn()
        |> post(~p"/device/decide", %{
          "user_code" => code,
          "decision" => "approve",
          "identity_id" => "new",
          "new_identity" => attrs
        })
        |> html_response(200)

      assert html =~ ~s(id="device-sign-in")
      Repo.update_all(DeviceCode, set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1)])
      assert new_agent_post(user, code, attrs).status == 400
      %{"user_code" => code} = start!()
      for _ <- 1..10, do: DeviceAttempts.record_failure(user.id)
      assert new_agent_post(user, code, attrs).status == 400
      assert Accounts.list_agent_identities_for(user) == []
    end
  end

  test "denying stops the CLI with access_denied", %{user: user} do
    %{"device_code" => device_code, "user_code" => user_code} = start!()

    html =
      user
      |> signed_in()
      |> post(~p"/device/decide", %{"user_code" => user_code, "decision" => "deny"})
      |> html_response(200)

    assert html =~ ~s(id="device-denied")
    assert error(poll(device_code)) == {400, "access_denied"}
  end

  test "an expired code is expired_token, and the page says so", %{user: user} do
    %{"device_code" => device_code, "user_code" => user_code} = start!()
    Repo.update_all(DeviceCode, set: [expires_at: ~U[2020-01-01 00:00:00Z]])

    assert error(poll(device_code)) == {400, "expired_token"}

    html =
      user |> signed_in() |> post(~p"/device", %{"user_code" => user_code}) |> html_response(400)

    assert html =~ "That code expired"
  end

  test "after 10 wrong codes the page refuses codes and decisions, even a right one", %{
    user: user
  } do
    %{"user_code" => user_code} = start!()

    for _ <- 1..10 do
      html =
        user
        |> signed_in()
        |> post(~p"/device", %{"user_code" => "BBBB-BBBB"})
        |> html_response(400)

      assert html =~ "That code isn&#39;t valid"
    end

    html =
      user |> signed_in() |> post(~p"/device", %{"user_code" => user_code}) |> html_response(400)

    assert html =~ "Too many wrong codes"

    # Deciding directly is limited too: guessing there would sign someone
    # else's CLI in as the guesser.
    assert user
           |> signed_in()
           |> post(~p"/device/decide", %{"user_code" => user_code, "decision" => "approve"})
           |> html_response(400) =~ "Too many wrong codes"
  end

  test "the CLI's client gets only CLI tokens, and no other client gets them" do
    # Not the agent APIs.
    assert error(start(%{"resource" => "https://reviews.test/api/test"})) ==
             {400, "invalid_scope"}

    assert error(start(%{"resource" => "https://reviews.test"})) == {400, "unauthorized_client"}

    # Not the authorization code grant: no consent page, no agents.
    conn =
      build_conn()
      |> get(~p"/oauth/authorize", %{
        "response_type" => "code",
        "client_id" => "reviews-cli",
        "redirect_uri" => "http://127.0.0.1/cb",
        "code_challenge" => String.duplicate("a", 43),
        "code_challenge_method" => "S256"
      })

    assert conn.status == 400

    # Another app that declares the device grant can't reach the CLI API.
    other = "https://other-cli.example/client.json"
    Fetcher.setup()

    Fetcher.put(other, %{
      "client_id" => other,
      "token_endpoint_auth_method" => "none",
      "grant_types" => [@grant]
    })

    assert error(start(%{"client_id" => other, "resource" => @cli_api})) ==
             {400, "unauthorized_client"}
  end

  test "a device request for another resource can't be approved at /device", %{user: user} do
    other = "https://agent-tv.example/client.json"
    Fetcher.setup()

    Fetcher.put(other, %{
      "client_id" => other,
      "token_endpoint_auth_method" => "none",
      "grant_types" => [@grant]
    })

    %{"user_code" => user_code} =
      start(%{"client_id" => other, "resource" => "https://reviews.test/api/test"})
      |> json_response(200)

    html =
      user |> signed_in() |> post(~p"/device", %{"user_code" => user_code}) |> html_response(400)

    assert html =~ "That code isn&#39;t valid"

    assert OAuth.approve_device(user, user_code, to_string(user.id)) ==
             {:error, :invalid_user_code}
  end

  test "the person can choose one of their agents at /device", %{user: user, human: human} do
    {:ok, agent} = Accounts.create_agent_identity(user, %{display_name: "Bot", handle: "bot"})
    %{"device_code" => device_code, "user_code" => user_code} = start!()

    html =
      user |> signed_in() |> post(~p"/device", %{"user_code" => user_code}) |> html_response(200)

    assert html =~ ~s(id="device-identity-#{human.id}")
    assert html =~ ~s(id="device-identity-#{agent.id}")

    html =
      user
      |> signed_in()
      |> post(~p"/device/decide", %{
        "user_code" => user_code,
        "decision" => "approve",
        "identity_id" => to_string(agent.id)
      })
      |> html_response(200)

    assert html =~ ~s(id="device-approved")

    me = poll(device_code) |> json_response(200) |> Map.fetch!("access_token") |> me()
    me = json_response(me, 200)
    assert me["username"] == user.username
    assert me["identity"]["id"] == agent.id
    assert me["identity"]["kind"] == "agent"
  end

  test "someone else's identity can't be chosen, and doesn't use up the code", %{user: user} do
    {:ok, other_user} =
      Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: "mallory"
      })

    {:ok, theirs} =
      Accounts.create_agent_identity(other_user, %{display_name: "Theirs", handle: "theirs"})

    {:ok, their_human} = Accounts.ensure_human_identity(other_user)
    %{"device_code" => device_code, "user_code" => user_code} = start!()

    for id <- [theirs.id, their_human.id, "nope", nil] do
      html =
        user
        |> signed_in()
        |> post(~p"/device/decide", %{
          "user_code" => user_code,
          "decision" => "approve",
          "identity_id" => id
        })
        |> html_response(200)

      assert html =~ "Choose one of your identities."
      assert html =~ ~s(id="device-confirm-form")
    end

    assert OAuth.approve_device(user, user_code, theirs.id) == {:error, :invalid_identity}
    wait()
    assert error(poll(device_code)) == {400, "authorization_pending"}
    assert DeviceAttempts.allowed?(user.id)
  end

  test "a grant for an identity its approver doesn't own is refused at /api/v1", %{user: user} do
    {:ok, other_user} =
      Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: "eve"
      })

    {:ok, theirs} = Accounts.create_agent_identity(other_user, %{display_name: "E", handle: "e"})
    %{"device_code" => device_code, "user_code" => user_code} = start!()

    # Bypasses the page's ownership check, as a bug elsewhere might.
    :ok =
      DeviceAuthorization.approve(OAuth.config(), user_code, subject: theirs.id, owner: user.id)

    %{"access_token" => access} = poll(device_code) |> json_response(200)
    assert me(access).status == 401
  end

  test "a human identity is refused at every API but the CLI's", %{user: user, human: human} do
    other = "https://agent-tv2.example/client.json"
    Fetcher.setup()

    Fetcher.put(other, %{
      "client_id" => other,
      "token_endpoint_auth_method" => "none",
      "grant_types" => [@grant]
    })

    %{"device_code" => device_code, "user_code" => user_code} =
      start(%{"client_id" => other, "resource" => "https://reviews.test/api/test"})
      |> json_response(200)

    :ok =
      DeviceAuthorization.approve(OAuth.config(), user_code, subject: human.id, owner: user.id)

    %{"access_token" => access} = poll(device_code, other) |> json_response(200)

    assert OAuth.authenticate_access_token("https://reviews.test/api/test", %{
             authorization: "Bearer " <> access,
             dpop: [],
             method: "GET",
             path: "/api/test"
           }) == {:error, :invalid_token}
  end

  test "a CLI token can push a review: API writes authenticate it before parsing", %{
    user: user,
    human: human
  } do
    %{"device_code" => device_code, "user_code" => user_code} = start!()
    :ok = OAuth.approve_device(user, user_code, human.id)
    %{"access_token" => access} = poll(device_code) |> json_response(200)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> access)
      |> put_req_header("content-type", "application/json")
      |> post(
        ~p"/api/v1/reviews",
        JSON.encode!(%{
          title: "Pushed after reviews login",
          raw_diff: "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n+new\n"
        })
      )

    assert %{"slug" => slug} = json_response(conn, 201)
    assert Reviews.Reviews.get_review_by_slug(slug).author_id == human.id
  end

  test "Settings lists CLI sign-ins apart from connected agents", %{user: user, human: human} do
    %{"device_code" => device_code, "user_code" => user_code} = start!()
    :ok = OAuth.approve_device(user, user_code, human.id)
    poll(device_code) |> json_response(200)
    [grant] = OAuth.list_grants_for(user)

    {:ok, view, _html} = live(signed_in(user), ~p"/settings")
    assert has_element?(view, "#cli-session-#{grant.id}", "Reviews CLI")
    assert has_element?(view, "#cli-session-#{grant.id}", "Acts as #{human.display_name}")
    refute has_element?(view, "#agent-link-#{grant.id}")

    view
    |> element("#sign-out-cli-#{grant.id}")
    |> render_click()

    refute has_element?(view, "#cli-session-#{grant.id}")
    assert Repo.one(from g in Reviews.OAuth.Grant, where: g.id == ^grant.id, select: g.revoked_at)
  end
end
