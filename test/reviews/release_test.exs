defmodule Reviews.ReleaseTest do
  use Reviews.DataCase, async: false

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

    test "creates identity-backed preview token when the preview database has the identity schema" do
      install_identity_schema!()

      raw = "rev_test_preview_token_identity"

      assert :ok = Release.seed_preview_token(raw)
      assert {:ok, user} = Accounts.authenticate_token(raw)
      assert user.username == "preview"

      %{rows: [[identity_id]]} =
        Repo.query!("SELECT identity_id FROM api_tokens WHERE name = 'preview-bootstrap'")

      assert is_integer(identity_id)

      %{rows: [["human", "preview", "preview"]]} =
        Repo.query!(
          "SELECT kind, handle, display_name FROM identities WHERE id = $1",
          [identity_id]
        )
    end
  end

  defp install_identity_schema! do
    Repo.query!("""
    CREATE TABLE identities (
      id bigserial PRIMARY KEY,
      owner_user_id bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      kind varchar(255) NOT NULL,
      handle varchar(255) NOT NULL,
      display_name varchar(255) NOT NULL,
      avatar_url varchar(255),
      provider varchar(255),
      description text,
      inserted_at timestamp(0) without time zone NOT NULL,
      updated_at timestamp(0) without time zone NOT NULL
    )
    """)

    Repo.query!("CREATE INDEX identities_owner_user_id_index ON identities (owner_user_id)")

    Repo.query!(
      "CREATE UNIQUE INDEX identities_owner_user_id_handle_index ON identities (owner_user_id, handle)"
    )

    Repo.query!("""
    CREATE UNIQUE INDEX identities_one_human_per_user
    ON identities (owner_user_id)
    WHERE kind = 'human'
    """)

    Repo.query!(
      "ALTER TABLE api_tokens ADD COLUMN identity_id bigint REFERENCES identities(id) ON DELETE RESTRICT"
    )

    Repo.query!("ALTER TABLE api_tokens ALTER COLUMN identity_id SET NOT NULL")
    Repo.query!("CREATE INDEX api_tokens_identity_id_index ON api_tokens (identity_id)")
  end
end
