defmodule Reviews.ReleaseTest do
  use Reviews.DataCase, async: true

  alias Reviews.Accounts
  alias Reviews.Release

  describe "seed_preview_token/1" do
    test "creates the preview user + token on first call, then authenticates" do
      raw = "rev_test_preview_token_aaa"

      assert :ok = Release.seed_preview_token(raw)
      assert {:ok, user} = Accounts.authenticate_token(raw)
      assert user.username == "preview"
      assert user.github_id == 0
    end

    test "is idempotent — second call with the same token is a no-op" do
      raw = "rev_test_preview_token_bbb"

      assert :ok = Release.seed_preview_token(raw)
      assert :ok = Release.seed_preview_token(raw)

      [%{username: "preview"}] = Repo.all(Reviews.Accounts.User)
      [_one_token] = Repo.all(Reviews.Accounts.ApiToken)
    end

    test "rotation adds a new token without losing the user" do
      assert :ok = Release.seed_preview_token("rev_test_old")
      assert :ok = Release.seed_preview_token("rev_test_new")

      [%{username: "preview"}] = Repo.all(Reviews.Accounts.User)
      tokens = Repo.all(Reviews.Accounts.ApiToken)
      assert length(tokens) == 2

      assert {:ok, _} = Accounts.authenticate_token("rev_test_old")
      assert {:ok, _} = Accounts.authenticate_token("rev_test_new")
    end
  end
end
