defmodule ReviewsWeb.PoppyDiscoveryController do
  @moduledoc """
  Poppy discovery (spec 3): `poppy.json` and the OpenAPI description of the
  Poppy API. The domain's protected resource metadata (RFC 9728) and the
  issuer's metadata (RFC 8414) come from `ReviewsWeb.OAuthDiscoveryController`,
  because `Reviews.Poppy` is one of the issuer's resources.
  """
  use ReviewsWeb, :controller

  alias Reviews.{Paging, Poppy}

  def poppy_json(conn, _params) do
    issuer = Poppy.issuer()

    cached_json(conn, %{
      protocol_version: Poppy.protocol_version(),
      organization: %{name: "Reviews", domain: Poppy.organization_domain()},
      auth: %{scopes: Poppy.scopes(), scope_hints: Poppy.scope_hints()},
      apis: [
        %{
          type: "openapi",
          url: issuer <> ~p"/api/poppy/openapi.json",
          description:
            "Read code reviews and post review comments as a Reviews agent its owner approved"
        }
      ]
    })
  end

  def openapi(conn, _params) do
    issuer = Poppy.issuer()

    error = %{
      "type" => "object",
      "properties" => %{"error" => %{"type" => "string"}}
    }

    session_params = [
      %{
        "name" => "Poppy-Session",
        "in" => "header",
        "required" => true,
        "schema" => %{"type" => "string"},
        "description" => "Session JWT (Poppy 1.0, section 5.2)"
      },
      %{
        "name" => "Poppy-Version",
        "in" => "header",
        "required" => true,
        "schema" => %{"type" => "string", "example" => "1.0"}
      }
    ]

    cached_json(conn, %{
      "openapi" => "3.1.0",
      "info" => %{
        "title" => "Reviews Poppy API",
        "version" => "1.0.0",
        "description" =>
          "Signed-out requests carry only the Session header. Posting a comment needs sign-in: the owner of a Reviews agent identity approves your Personal Agent to act as that identity."
      },
      "servers" => [%{"url" => issuer <> "/api/poppy/v1"}],
      "components" => %{
        "securitySchemes" => %{
          "reviews_oauth" => %{
            "type" => "oauth2",
            "flows" => %{
              "authorizationCode" => %{
                "authorizationUrl" => issuer <> ~p"/oauth/authorize",
                "tokenUrl" => issuer <> ~p"/oauth/token",
                "refreshUrl" => issuer <> ~p"/oauth/token",
                "scopes" => Poppy.scopes()
              }
            }
          }
        }
      },
      "paths" => %{
        "/reviews/{slug}/files" => page_path("files", session_params),
        "/reviews/{slug}/threads" => page_path("threads", session_params),
        "/reviews/{slug}/threads/{thread_id}/comments" => page_path("comments", session_params),
        "/reviews/{slug}" => %{
          "get" => %{
            "operationId" => "getReview",
            "summary" => "Read a review: patchsets, files, packet, and published threads",
            "parameters" => [
              %{
                "name" => "slug",
                "in" => "path",
                "required" => true,
                "schema" => %{"type" => "string"}
              }
              | session_params
            ],
            "responses" => %{
              "200" => %{"description" => "The review"},
              "400" => %{"description" => "Session error", "content" => json_schema(error)},
              "404" => %{"description" => "No such review"}
            }
          }
        },
        "/reviews/{slug}/comments" => %{
          "post" => %{
            "operationId" => "createComment",
            "summary" => "Post a comment, or a reply with thread_id, as the linked Reviews agent",
            "security" => [%{"reviews_oauth" => ["comments:write"]}],
            "parameters" => [
              %{
                "name" => "slug",
                "in" => "path",
                "required" => true,
                "schema" => %{"type" => "string"}
              }
              | session_params
            ],
            "requestBody" => %{
              "required" => true,
              "content" =>
                json_schema(%{
                  "type" => "object",
                  "required" => ["file_path", "body", "thread_anchor"],
                  "properties" => %{
                    "file_path" => %{"type" => "string"},
                    "side" => %{"type" => "string", "enum" => ["old", "new"], "default" => "new"},
                    "body" => %{"type" => "string", "description" => "Markdown"},
                    "thread_id" => %{"type" => "integer", "description" => "Reply to this thread"},
                    "thread_anchor" => %{
                      "type" => "object",
                      "required" => ["granularity", "line_number_hint"],
                      "properties" => %{
                        "granularity" => %{"type" => "string", "enum" => ["line"]},
                        "line_number_hint" => %{"type" => "integer"}
                      }
                    }
                  }
                })
            },
            "responses" => %{
              "201" => %{"description" => "Published"},
              "400" => %{"description" => "Session error", "content" => json_schema(error)},
              "401" => %{"description" => "Sign-in needed, or the access token is invalid"},
              "403" => %{"description" => "insufficient_scope"},
              "404" => %{"description" => "No such review or thread"},
              "422" => %{"description" => "Invalid comment"}
            }
          }
        }
      }
    })
  end

  defp page_path(kind, session_params) do
    query = fn name, schema -> %{"name" => name, "in" => "query", "schema" => schema} end

    parameters =
      [
        %{
          "name" => "slug",
          "in" => "path",
          "required" => true,
          "schema" => %{"type" => "string"}
        },
        query.("revision", %{"type" => "integer", "minimum" => 1, "maximum" => 2_147_483_647}),
        query.("limit", %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => Paging.max_limit(),
          "default" => Paging.default_limit()
        }),
        query.("max_bytes", %{
          "type" => "integer",
          "minimum" => Paging.min_max_bytes(),
          "maximum" => Paging.max_bytes_limit(),
          "default" => Paging.default_max_bytes()
        }),
        query.("cursor", %{
          "type" => "string",
          "description" =>
            "Opaque query-bound cursor: return next_cursor unchanged with the same endpoint, review, revision, thread and filters. REST/Poppy cursors are not MCP cursors."
        })
      ] ++ session_params

    parameters =
      case kind do
        "comments" ->
          [
            %{
              "name" => "thread_id",
              "in" => "path",
              "required" => true,
              "schema" => %{"type" => "integer"}
            }
            | parameters
          ]

        "threads" ->
          parameters ++
            [
              query.("status", %{"enum" => ["open", "resolved"]}),
              query.("path", %{"type" => "string"})
            ]

        _ ->
          parameters
      end

    item =
      case kind do
        "files" ->
          %{
            "type" => "object",
            "required" => ["path", "status", "bytes"],
            "properties" => %{"path" => %{"type" => "string"}, "bytes" => %{"type" => "integer"}}
          }

        "threads" ->
          %{
            "type" => "object",
            "required" => ["id", "anchor_status", "originating_revision", "comment_count"],
            "properties" => %{
              "id" => %{"type" => "integer"},
              "anchor_status" => %{"enum" => ["current", "outdated"]}
            }
          }

        "comments" ->
          %{
            "type" => "object",
            "required" => ["id", "body", "offset", "complete"],
            "properties" => %{
              "id" => %{"type" => "integer"},
              "body" => %{"type" => "string"},
              "offset" => %{"type" => "integer"},
              "complete" => %{"type" => "boolean"}
            }
          }
      end

    schema = %{
      "type" => "object",
      "required" => ["slug", "revision", "next_cursor", kind],
      "properties" => %{
        "slug" => %{"type" => "string"},
        "revision" => %{"type" => "integer"},
        "next_cursor" => %{"type" => ["string", "null"]},
        kind => %{"type" => "array", "items" => item}
      }
    }

    %{
      "get" => %{
        "operationId" => "listReview" <> String.capitalize(kind),
        "summary" => "Bounded " <> kind <> " page; long comments continue as UTF-8 body chunks",
        "parameters" => parameters,
        "responses" => %{
          "200" => %{"description" => "Page", "content" => json_schema(schema)},
          "400" => %{"description" => "Session error"},
          "404" => %{"description" => "Review, revision or thread not found"},
          "422" => %{"description" => "Invalid pagination parameters or insufficient byte budget"}
        }
      }
    }
  end

  defp json_schema(schema), do: %{"application/json" => %{"schema" => schema}}

  defp cached_json(conn, body) do
    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> json(body)
  end
end
