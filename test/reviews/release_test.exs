defmodule Reviews.ReleaseTest do
  use Reviews.DataCase, async: true

  alias Reviews.Accounts
  alias Reviews.Release

  describe "seed_preview_token/1" do
    test "creates the preview user + token on first call, then authenticates" do
      raw = "rev_test_preview_token_aaa"

      assert :ok = Release.seed_preview_token(raw)
      assert {:ok, %{user: user, identity: identity}} = Accounts.authenticate_token(raw)
      assert user.username == "preview"
      assert user.github_id == 0
      assert identity.handle == "preview"
    end

    test "is idempotent — second call with the same token is a no-op" do
      raw = "rev_test_preview_token_bbb"

      assert :ok = Release.seed_preview_token(raw)
      assert :ok = Release.seed_preview_token(raw)

      assert [%{username: "preview"}] =
               Repo.all(
                 from u in Reviews.Accounts.User,
                   where: u.github_id == 0
               )

      assert [_one_token] =
               Repo.all(
                 from t in Reviews.Accounts.ApiToken,
                   join: u in assoc(t, :user),
                   where: u.github_id == 0
               )
    end

    test "rotation adds a new token without losing the user" do
      assert :ok = Release.seed_preview_token("rev_test_old")
      assert :ok = Release.seed_preview_token("rev_test_new")

      assert [%{username: "preview"}] =
               Repo.all(
                 from u in Reviews.Accounts.User,
                   where: u.github_id == 0
               )

      tokens =
        Repo.all(
          from t in Reviews.Accounts.ApiToken,
            join: u in assoc(t, :user),
            where: u.github_id == 0
        )

      assert length(tokens) == 2

      assert {:ok, %{identity: %{handle: "preview"}}} =
               Accounts.authenticate_token("rev_test_old")

      assert {:ok, %{identity: %{handle: "preview"}}} =
               Accounts.authenticate_token("rev_test_new")
    end
  end
end
