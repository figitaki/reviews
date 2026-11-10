defmodule ReviewsWeb.Api.CapabilityControllerTest do
  use ReviewsWeb.ConnCase, async: true

  test "returns disabled code storage with the configured limits by default", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/capabilities")

    assert %{
             "code_storage" => %{
               "enabled" => false,
               "required" => false,
               "supported_object_formats" => ["sha1"],
               "max_upload_bytes" => 536_870_912
             },
             "lsp" => %{"enabled" => false, "languages" => []}
           } = json_response(conn, 200)
  end

  test "requires no authentication", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/capabilities")
    assert json_response(conn, 200)
  end
end
