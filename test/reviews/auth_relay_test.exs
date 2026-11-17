defmodule Reviews.AuthRelayTest do
  use Reviews.DataCase

  alias Reviews.AuthRelay

  @host "reviews-pr-42.fly.dev"
  @user %{github_id: 9001, username: "octo", avatar_url: nil, email: "octo@example.com"}

  setup do
    original = Application.get_env(:reviews, :auth_relay)
    Application.put_env(:reviews, :auth_relay, secret: String.duplicate("s", 64))
    on_exit(fn -> Application.put_env(:reviews, :auth_relay, original) end)

    %{state: AuthRelay.new_state()}
  end

  test "allowed_host? accepts only reviews-pr-<digits>.fly.dev" do
    assert AuthRelay.allowed_host?("reviews-pr-1.fly.dev")
    assert AuthRelay.allowed_host?("reviews-pr-156.fly.dev")

    for host <- [
          "reviews.figitaki.dev",
          "reviews-dev.fly.dev",
          "reviews-pr-.fly.dev",
          "reviews-pr-1a.fly.dev",
          "REVIEWS-PR-1.FLY.DEV",
          "reviews-pr-1.fly.dev.evil.example",
          "evil.reviews-pr-1.fly.dev",
          "reviews-pr-1.fly.dev:8443",
          "reviews-pr-1.fly.dev/x",
          "reviews-pr-1.fly.dev@evil.example",
          "reviews-pr-1.fly.dev\n",
          "https://reviews-pr-1.fly.dev",
          "",
          nil
        ] do
      refute AuthRelay.allowed_host?(host), "accepted #{inspect(host)}"
    end
  end

  test "a code redeems once, on its host, for its state", %{state: state} do
    code = AuthRelay.issue_code(@host, state, @user)

    assert AuthRelay.redeem_code(code, @host, state) == {:ok, @user}
    assert AuthRelay.redeem_code(code, @host, state) == {:error, :replayed}
  end

  test "a code for one preview does not work on another", %{state: state} do
    code = AuthRelay.issue_code(@host, state, @user)

    assert AuthRelay.redeem_code(code, "reviews-pr-43.fly.dev", state) == {:error, :wrong_host}
    # A rejected attempt does not use the code up.
    assert {:ok, _} = AuthRelay.redeem_code(code, @host, state)
  end

  test "a code needs the state from the browser that started sign-in", %{state: state} do
    code = AuthRelay.issue_code(@host, state, @user)

    assert AuthRelay.redeem_code(code, @host, AuthRelay.new_state()) == {:error, :wrong_state}
    assert AuthRelay.redeem_code(code, @host, nil) == {:error, :wrong_state}
  end

  test "a code expires after 60 seconds", %{state: state} do
    now = System.system_time(:second)

    fresh = AuthRelay.issue_code(@host, state, @user, signed_at: now - 50)
    stale = AuthRelay.issue_code(@host, state, @user, signed_at: now - 61)

    assert {:ok, _} = AuthRelay.redeem_code(fresh, @host, state)
    assert AuthRelay.redeem_code(stale, @host, state) == {:error, :expired}
  end

  test "rejects tampered codes and codes made with another secret", %{state: state} do
    code = AuthRelay.issue_code(@host, state, @user)
    tampered = String.slice(code, 0..-6//1) <> "AAAAA"

    assert AuthRelay.redeem_code(tampered, @host, state) == {:error, :invalid}
    assert AuthRelay.redeem_code(["list"], @host, state) == {:error, :invalid}

    Application.put_env(:reviews, :auth_relay, secret: String.duplicate("t", 64))
    assert AuthRelay.redeem_code(code, @host, state) == {:error, :invalid}
  end
end
