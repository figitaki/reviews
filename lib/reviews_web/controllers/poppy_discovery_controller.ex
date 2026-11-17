defmodule ReviewsWeb.PoppyDiscoveryController do
  @moduledoc """
  Poppy discovery (spec 3): `poppy.json` and the OpenAPI description of the
  Poppy API. The domain's protected resource metadata (RFC 9728) and the
  issuer's metadata (RFC 8414) come from `ReviewsWeb.OAuthDiscoveryController`,
  because `Reviews.Poppy` is one of the issuer's resources.
  """
  use ReviewsWeb, :controller

  alias Reviews.Poppy

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
      "properties" => %{
        "error" => %{"type" => "string"},
        "error_code" => %{"type" => "string"},
        "error_detail" => %{"type" => "string"},
        "errors" => %{"type" => "object"}
      }
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
              "404" => %{"description" => "No such review", "content" => json_schema(error)}
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
                  "required" => ["body"],
                  "oneOf" => [
                    %{"required" => ["thread_id"]},
                    %{
                      "required" => ["file_path", "thread_anchor"],
                      "not" => %{"required" => ["thread_id"]}
                    }
                  ],
                  "properties" => %{
                    "file_path" => %{"type" => "string"},
                    "revision" => %{
                      "type" => "integer",
                      "minimum" => 1,
                      "description" => "Exact revision for a new thread; omitted selects latest"
                    },
                    "side" => %{"type" => "string", "enum" => ["old", "new"], "default" => "new"},
                    "body" => %{"type" => "string", "description" => "Markdown"},
                    "thread_id" => %{"type" => "integer", "description" => "Reply to this thread"},
                    "thread_anchor" => %{
                      "type" => "object",
                      "required" => ["granularity", "line_number_hint"],
                      "if" => %{"properties" => %{"granularity" => %{"const" => "token_range"}}},
                      "then" => %{"required" => ["selection_text"]},
                      "properties" => %{
                        "granularity" => %{"type" => "string", "enum" => ["line", "token_range"]},
                        "line_number_hint" => %{"type" => "integer", "minimum" => 1},
                        "selection_text" => %{"type" => "string", "minLength" => 1},
                        "selection_offset" => %{
                          "type" => "integer",
                          "minimum" => 0,
                          "description" => "UTF-16 code units"
                        }
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
              "404" => %{
                "description" => "No such review or thread",
                "content" => json_schema(error)
              },
              "422" => %{"description" => "Invalid comment", "content" => json_schema(error)}
            }
          }
        }
      }
    })
  end

  defp json_schema(schema), do: %{"application/json" => %{"schema" => schema}}

  defp cached_json(conn, body) do
    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> json(body)
  end
end
