defmodule ReviewsWeb.StaticFilesTest do
  # Writes digested copies into priv/static, so not async.
  use ReviewsWeb.ConnCase, async: false

  test "the page's manifest and every icon it lists are served", %{conn: conn} do
    document = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

    [href] =
      document |> LazyHTML.query("head link[rel='manifest']") |> LazyHTML.attribute("href")

    manifest_conn = get(build_conn(), href)
    assert manifest_conn.status == 200

    assert [content_type] = get_resp_header(manifest_conn, "content-type")
    assert content_type =~ "application/manifest+json"

    %{"icons" => [_ | _] = icons} = JSON.decode!(manifest_conn.resp_body)

    for %{"src" => src, "type" => type} <- icons do
      icon_conn = get(build_conn(), src)
      assert icon_conn.status == 200, "#{src} returned #{icon_conn.status}"
      assert [icon_type] = get_resp_header(icon_conn, "content-type")
      assert icon_type =~ type
    end
  end

  # In production `~p` links the digested names `mix phx.digest` writes,
  # such as /site-<hash>.webmanifest, so those must pass Plug.Static too.
  test "digested names of root files are served" do
    static = Application.app_dir(:reviews, "priv/static")
    digest = "0123456789abcdef0123456789abcdef"

    for {file, digested} <- [
          {"site.webmanifest", "site-#{digest}.webmanifest"},
          {"favicon.ico", "favicon-#{digest}.ico"}
        ] do
      path = Path.join(static, digested)
      File.cp!(Path.join(static, file), path)
      on_exit(fn -> File.rm(path) end)

      conn = get(build_conn(), "/#{digested}?vsn=d")
      assert conn.status == 200, "/#{digested} returned #{conn.status}"
      assert conn.resp_body == File.read!(Path.join(static, file))
    end
  end
end
