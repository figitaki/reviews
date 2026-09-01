# async: false — swaps the code-storage adapter config in global app env.
defmodule Reviews.CodeStorage.CodeDotStorageTest do
  use Reviews.DataCase, async: false

  import Reviews.CodeStorageFixtures

  alias Reviews.Accounts
  alias Reviews.CodeStorage.CodeDotStorage

  setup do
    jwk = JOSE.JWK.generate_key({:ec, :secp256r1})
    {_meta, pem} = JOSE.JWK.to_pem(jwk)

    original = Application.get_env(:reviews, Reviews.CodeStorage, [])

    config =
      Keyword.merge(original,
        adapter: CodeDotStorage,
        org: "acme",
        jwt_private_key: pem,
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    Application.put_env(:reviews, Reviews.CodeStorage, config)
    on_exit(fn -> Application.put_env(:reviews, Reviews.CodeStorage, original) end)

    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 7_777,
        username: "adapter",
        email: "adapter@example.com",
        avatar_url: nil
      })

    {:ok, identity} = Accounts.ensure_human_identity(user)

    repository = code_repository_fixture(identity)
    snapshot = code_snapshot_fixture(identity, repository)
    %{repository: repository, snapshot: snapshot, jwk: jwk}
  end

  test "create_repository posts /repos with a bearer JWT for the repo claim", ctx do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:req, conn.method, conn.request_path, auth_header(conn)})
      Req.Test.json(conn, %{"id" => "prov-123"})
    end)

    assert {:ok, %{storage_key: storage_key, provider_repo_id: "prov-123"}} =
             CodeDotStorage.create_repository(ctx.repository)

    assert storage_key == ctx.repository.storage_key
    assert_received {:req, "POST", "/api/repos", "Bearer " <> jwt}
    assert {true, %JOSE.JWT{fields: claims}, _} = JOSE.JWT.verify(ctx.jwk, jwt)
    assert claims["repo"] == ctx.repository.storage_key
    assert "repo:write" in claims["scopes"]
  end

  test "create_repository resolves an already-existing repo via GET", ctx do
    Req.Test.stub(__MODULE__, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/repos"} -> Plug.Conn.send_resp(conn, 409, "{}")
        {"GET", _} -> Req.Test.json(conn, %{"id" => "prov-existing"})
      end
    end)

    assert {:ok, %{provider_repo_id: "prov-existing"}} =
             CodeDotStorage.create_repository(ctx.repository)
  end

  test "upload_instructions returns a credential-free URL and a ref-scoped JWT", ctx do
    assert {:ok, %{remote_url: url, token: token, expires_at: %DateTime{}}} =
             CodeDotStorage.upload_instructions(ctx.repository, ctx.snapshot)

    assert url == "https://acme.code.storage/#{ctx.repository.storage_key}.git"
    refute String.contains?(url, token)

    assert {true, %JOSE.JWT{fields: claims}, _} = JOSE.JWT.verify(ctx.jwk, token)
    assert claims["scopes"] == ["git:write"]

    assert claims["refs"] == [
             ["snapshots/#{ctx.snapshot.public_id}/base", ["no-force-push"]],
             ["snapshots/#{ctx.snapshot.public_id}/head", ["no-force-push"]],
             ["*", ["no-push"]]
           ]
  end

  test "verify succeeds when both refs resolve to the reserved OIDs", ctx do
    Req.Test.stub(__MODULE__, fn conn ->
      sha =
        if String.ends_with?(conn.request_path, "base"),
          do: ctx.snapshot.base_oid,
          else: ctx.snapshot.head_oid

      Req.Test.json(conn, %{"sha" => sha})
    end)

    assert {:ok, %{base_oid: base, head_oid: head}} =
             CodeDotStorage.verify(ctx.repository, ctx.snapshot)

    assert base == ctx.snapshot.base_oid
    assert head == ctx.snapshot.head_oid
  end

  test "verify returns ref_mismatch on wrong OID and on missing ref", ctx do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"sha" => String.duplicate("f", 40)})
    end)

    assert {:error, :ref_mismatch} = CodeDotStorage.verify(ctx.repository, ctx.snapshot)

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 404, "{}") end)
    assert {:error, :ref_mismatch} = CodeDotStorage.verify(ctx.repository, ctx.snapshot)
  end

  test "delete_repository is idempotent on 404", ctx do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 404, "{}") end)
    assert :ok = CodeDotStorage.delete_repository(ctx.repository)
  end

  test "provider errors never contain the bearer token", ctx do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

    assert {:error, reason} = CodeDotStorage.verify(ctx.repository, ctx.snapshot)
    refute inspect(reason) =~ "Bearer"
    assert reason == {:http_status, 500}
  end

  test "misconfiguration is reported without provider calls", ctx do
    config = Application.get_env(:reviews, Reviews.CodeStorage, [])
    Application.put_env(:reviews, Reviews.CodeStorage, Keyword.delete(config, :org))

    assert {:error, :code_storage_misconfigured} =
             CodeDotStorage.create_repository(ctx.repository)
  end

  defp auth_header(conn) do
    conn |> Plug.Conn.get_req_header("authorization") |> List.first()
  end
end
