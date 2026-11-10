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
      {:ok, %{user: user}} = Accounts.authenticate_token(raw)
      [original_token] = Accounts.list_tokens_for(user)
      assert :ok = Release.seed_preview_token(raw)
      assert [^original_token] = Accounts.list_tokens_for(user)

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

    test "rotation replaces only the preview user's bootstrap tokens" do
      assert :ok = Release.seed_preview_token("rev_test_old")
      {:ok, %{user: preview}} = Accounts.authenticate_token("rev_test_old")
      {:ok, _, unrelated_raw} = Accounts.mint_token(preview, %{name: "laptop"})
      {:ok, _, legacy_raw} = Accounts.mint_token(preview, %{name: "preview-bootstrap"})

      {:ok, other_user} =
        Accounts.upsert_from_github(%{github_id: 1234, username: "other"})

      {:ok, _, other_raw} = Accounts.mint_token(other_user, %{name: "preview-bootstrap"})
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

      assert {:error, :invalid_token} = Accounts.authenticate_token("rev_test_old")
      assert {:error, :invalid_token} = Accounts.authenticate_token(legacy_raw)
      assert {:ok, _} = Accounts.authenticate_token(unrelated_raw)
      assert {:ok, _} = Accounts.authenticate_token(other_raw)

      assert {:ok, %{identity: %{handle: "preview"}}} =
               Accounts.authenticate_token("rev_test_new")
    end

    test "failed rotation rolls back deletion of the prior bootstrap token" do
      assert :ok = Release.seed_preview_token("rev_test_old")

      {:ok, other_user} =
        Accounts.upsert_from_github(%{github_id: 1234, username: "other"})

      {:ok, _, other_raw} = Accounts.mint_token(other_user)

      assert_raise Ecto.ConstraintError, fn -> Release.seed_preview_token(other_raw) end

      assert {:ok, _} = Accounts.authenticate_token("rev_test_old")
      assert {:ok, _} = Accounts.authenticate_token(other_raw)
    end
  end
end
