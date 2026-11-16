defmodule Reviews.CodeStorage.CodeDotStorage.ClientTest do
  use ExUnit.Case, async: true

  alias Reviews.CodeStorage.CodeDotStorage.Client

  setup do
    %{config: [org: "acme", req_options: [plug: {Req.Test, __MODULE__}]]}
  end

  describe "current provider contract" do
    test "resolves an encoded repository and query ref from nested commit metadata", %{
      config: config
    } do
      sha = String.duplicate("a", 40)

      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/api/repos/reviews%2Fabc/commit"
        assert URI.decode_query(conn.query_string) == %{"ref" => "snapshots/a/head"}
        Req.Test.json(conn, %{"commit" => %{"sha" => sha}})
      end)

      assert {:ok, %{sha: ^sha}} =
               Client.get_commit(config, "synthetic", "reviews/abc", "snapshots/a/head")
    end

    test "rejects malformed successful commit responses", %{config: config} do
      for body <- [
            %{},
            %{"sha" => String.duplicate("a", 40)},
            %{"commit" => %{"sha" => nil}},
            %{"commit" => %{"sha" => "not-an-oid"}},
            %{"commit" => %{"sha" => String.duplicate("g", 40)}}
          ] do
        Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, body) end)

        assert {:error, :invalid_response} =
                 Client.get_commit(config, "synthetic", "reviews/abc", "main")
      end
    end

    test "reads repo_id from repository metadata and repo_name from create", %{config: config} do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.method do
          "POST" -> Req.Test.json(conn, %{"repo_name" => "reviews/abc", "message" => "created"})
          "GET" -> Req.Test.json(conn, %{"repo_id" => "repo_123", "repo_name" => "reviews/abc"})
        end
      end)

      assert {:ok, %{provider_repo_id: "reviews/abc"}} =
               Client.create_repo(config, "synthetic", "reviews/abc")

      assert {:ok, %{provider_repo_id: "repo_123"}} =
               Client.get_repo(config, "synthetic", "reviews/abc")
    end

    test "does not turn a create conflict into success", %{config: config} do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.method == "POST"
        Plug.Conn.send_resp(conn, 409, "{}")
      end)

      assert {:error, {:http_status, 409}} =
               Client.create_repo(config, "synthetic", "reviews/abc")
    end

    test "preserves authorization failures without echoing response bodies", %{config: config} do
      Req.Test.stub(__MODULE__, fn conn ->
        Plug.Conn.send_resp(conn, 403, "SYNTHETIC_SECRET_SENTINEL")
      end)

      assert {:error, {:http_status, 403}} =
               Client.get_commit(config, "synthetic", "reviews/abc", "main")
    end

    test "does not follow redirects on authenticated provider requests", %{config: config} do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.host == "api.acme.code.storage"

        conn
        |> Plug.Conn.put_resp_header("location", "https://unexpected.invalid/")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, {:http_status, 302}} =
               Client.get_commit(config, "synthetic", "reviews/abc", "main")
    end
  end
end
