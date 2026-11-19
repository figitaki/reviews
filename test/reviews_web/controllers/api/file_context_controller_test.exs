defmodule ReviewsWeb.Api.FileContextControllerTest do
  use ReviewsWeb.ConnCase, async: false

  import Reviews.CodeStorageFixtures

  alias Reviews.CodeStorage
  alias Reviews.CodeStorage.CodeDotStorage
  alias Reviews.Reviews, as: ReviewsContext

  @diff "diff --git a/old name.js b/new name.js\nsimilarity index 90%\nrename from old name.js\nrename to new name.js\n--- a/old name.js\n+++ b/new name.js\n@@ -2 +2 @@\n-old\n+new\n"

  setup do
    {_meta, pem} = JOSE.JWK.generate_key({:ec, :secp256r1}) |> JOSE.JWK.to_pem()
    original = Application.get_env(:reviews, CodeStorage, [])

    Application.put_env(:reviews, CodeStorage,
      adapter: CodeDotStorage,
      org: "acme",
      jwt_private_key: pem,
      req_options: [plug: {Req.Test, __MODULE__}]
    )

    on_exit(fn -> Application.put_env(:reviews, CodeStorage, original) end)
    %{identity: identity} = code_storage_identity_fixture()
    repository = code_repository_fixture(identity, %{status: "ready"})
    snapshot = code_snapshot_fixture(identity, repository)

    {:ok, %{review: review, files: [file]}} =
      ReviewsContext.create_review_with_initial_patchset(identity, %{
        title: "Context",
        raw_diff: @diff,
        code_snapshot_id: snapshot.public_id
      })

    %{identity: identity, review: review, diff_file: file}
  end

  test "a link reader gets both renamed file sides from verified commits", ctx do
    base = base_oid()
    head = head_oid()

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path =~ "/file"
      assert Plug.Conn.get_req_header(conn, "range") == ["bytes=0-1048576"]
      params = URI.decode_query(conn.query_string)

      body =
        case params do
          %{"ref" => ^base, "path" => "old name.js"} ->
            "before\nold\nafter\n"

          %{"ref" => ^head, "path" => "new name.js"} ->
            "before\nnew\nafter\n"
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/octet-stream")
      |> Plug.Conn.send_resp(200, body)
    end)

    conn = get(build_conn(), context_path(ctx))

    assert %{
             "old" => "before\nold\nafter\n",
             "new" => "before\nnew\nafter\n",
             "raw_diff" => @diff
           } = json_response(conn, 200)

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "file IDs and revisions cannot read across reviews", ctx do
    {:ok, %{review: other}} =
      ReviewsContext.create_review_with_initial_patchset(ctx.identity, %{
        title: "Other",
        raw_diff: @diff
      })

    assert get(build_conn(), context_path(ctx, other.slug)) |> json_response(404)

    assert get(
             build_conn(),
             "/api/v1/reviews/#{ctx.review.slug}/patchsets/2/files/#{ctx.diff_file.id}/context"
           )
           |> json_response(404)

    assert get(
             build_conn(),
             "/api/v1/reviews/#{ctx.review.slug}/patchsets/bad/files/#{ctx.diff_file.id}/context"
           )
           |> json_response(404)
  end

  test "diff-only uploads remain readable and explain missing context", ctx do
    {:ok, %{review: review, files: [file]}} =
      ReviewsContext.create_review_with_initial_patchset(ctx.identity, %{
        title: "Diff only",
        raw_diff: @diff
      })

    assert %{"error" => "Context was not uploaded for this patchset."} =
             get(build_conn(), context_path(%{review: review, diff_file: file}))
             |> json_response(409)

    assert get(build_conn(), ~p"/r/#{review.slug}") |> html_response(200)
  end

  test "oversized, binary and invalid UTF-8 sources fail without returning code", ctx do
    for {body, status} <- [{String.duplicate("x", 1_048_577), 413}, {"a\0b", 422}, {<<255>>, 422}] do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
      assert %{"error" => _} = get(build_conn(), context_path(ctx)) |> json_response(status)
    end

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-range", "bytes 0-10/2000000")
      |> Plug.Conn.send_resp(206, "short")
    end)

    assert get(build_conn(), context_path(ctx)) |> json_response(413)
  end

  test "provider failures do not echo credentials or upstream bodies", ctx do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 403, "SYNTHETIC_SECRET") end)

    assert %{"error" => "Could not load context. Try again."} =
             get(build_conn(), context_path(ctx)) |> json_response(502)
  end

  defp context_path(ctx, slug \\ nil),
    do: "/api/v1/reviews/#{slug || ctx.review.slug}/patchsets/1/files/#{ctx.diff_file.id}/context"
end
