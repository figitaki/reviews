defmodule ReviewsWeb.MCP.Server do
  @moduledoc """
  Hosted MCP server (Streamable HTTP at `/mcp`), built on FastestMCP.

  Callers authenticate with a bearer token of one of two kinds:

    * a Reviews API token, the same token the CLI uses. API tokens have no
      scope model yet, so each holds every scope below.
    * an OAuth access token the Reviews issuer minted for this endpoint
      (`Reviews.MCPAuth`), which holds the scopes its owner approved. Claude
      and ChatGPT connectors get these by signing in.

  The token's identity is the actor for every call, so agent identities keep
  their attribution. A 401 names the endpoint's protected resource metadata
  (RFC 9728), which leads clients to the issuer.

  The endpoint and its write tools are off unless configured:

      config :reviews, :mcp, enabled: true, writes_enabled: true

  See `docs/MCP.md`.
  """
  use FastestMCP.ServerModule, otp_app: :reviews

  alias FastestMCP.Authorization
  alias Reviews.{Accounts, MCPAuth, OAuth, Paging}
  alias ReviewsWeb.MCP.Handlers

  @scopes ["reviews:read", "reviews:write", "comments:write", "threads:write"]

  @instructions """
  Reviews hosts code reviews: a diff plus a packet that orders hunks into narrated sections, \
  with threaded line comments. Use these tools to read a review you or your agents pushed \
  (outline, packet sections, file diffs) and the feedback on it (open threads), then reply \
  to or resolve threads and push revisions. Reviews are identified by slug or /r/<slug> URL. \
  Comments publish immediately under the token's identity.\
  """

  def enabled?, do: Keyword.get(config(), :enabled, false)
  def writes_enabled?, do: enabled?() and Keyword.get(config(), :writes_enabled, false)
  def allowed_hosts, do: Keyword.get(config(), :allowed_hosts, :localhost)
  defp config, do: Application.get_env(:reviews, :mcp, [])

  @doc """
  Resolves the bearer token on every request, including later requests of a
  session, so a revoked token or link stops working on its next call. OAuth
  tokens issued for another API are refused.
  """
  def authenticate(input, _ctx) do
    with "Bearer " <> token <- input["authorization"] || "",
         {:ok, principal, scopes} <- authenticate_bearer(token) do
      {:ok, %{principal: principal, scopes: scopes}}
    else
      _ -> {:error, :unauthorized}
    end
  end

  # The principal is plain data; `ReviewsWeb.MCP.Handlers` turns it into a
  # `Reviews.Principal`. An OAuth token also names its grant and client, so
  # its writes are limited to its scopes and recorded with attribution.
  defp authenticate_bearer(token) do
    case Accounts.authenticate_token(token) do
      {:ok, %{user: user, identity: identity}} ->
        {:ok, %{"identity_id" => identity.id, "user_id" => user.id}, @scopes}

      {:error, _} ->
        request = %{
          authorization: "Bearer " <> token,
          dpop: [],
          method: "POST",
          path: "/mcp"
        }

        case OAuth.authenticate_access_token(MCPAuth.resource(), request) do
          {:ok, %{grant: grant, token: oauth_token}} ->
            {:ok,
             %{
               "identity_id" => grant.identity.id,
               "user_id" => grant.approved_by_user.id,
               "grant_id" => grant.id,
               "client_id" => oauth_token.client_id,
               "scopes" => oauth_token.scopes
             }, oauth_token.scopes}

          {:error, _} ->
            :error
        end
    end
  end

  @doc """
  The `WWW-Authenticate` value for a 401 or 403 from `/mcp`: FastestMCP's
  Bearer challenge (`existing`, or nil), with the protected resource metadata
  URL (RFC 9728 §5.1) first and, unless it names the missing scopes, every
  scope the endpoint offers.
  """
  def challenge(existing) do
    params =
      case existing do
        "Bearer" <> rest -> rest |> String.trim() |> String.trim_leading(",") |> String.trim()
        _ -> ""
      end

    scope =
      if params =~ ~r/(^|[\s,])scope=/,
        do: [],
        else: [~s(scope="#{Enum.join(MCPAuth.scope_names(), " ")}")]

    ([~s(resource_metadata="#{MCPAuth.resource_metadata_url()}")] ++
       scope ++ if(params == "", do: [], else: [params]))
    |> Enum.join(", ")
    |> then(&("Bearer " <> &1))
  end

  @impl true
  def server(opts) do
    writes? = writes_enabled?()

    opts
    |> Keyword.put(:metadata, %{
      title: "Reviews",
      version: to_string(Application.spec(:reviews, :vsn)),
      instructions: @instructions,
      website_url: "https://github.com/figitaki/reviews"
    })
    |> base_server()
    |> FastestMCP.add_auth(&authenticate/2)
    |> FastestMCP.add_middleware(
      FastestMCP.Middleware.rate_limiting(
        max_requests_per_second: Keyword.get(config(), :requests_per_second, 5.0),
        burst_capacity: Keyword.get(config(), :burst, 20),
        get_client_id: fn operation -> operation.context.principal["identity_id"] end
      )
    )
    |> add_read_tools()
    |> add_write_tools(writes?)
    |> FastestMCP.add_resource_template(
      "reviews://{slug}/feedback",
      &Handlers.feedback_markdown/2,
      name: "review-feedback",
      title: "Open feedback",
      description:
        "Open threads on the latest revision of a review, as Markdown anchored to path:line.",
      mime_type: "text/markdown",
      authorization: Authorization.require_scopes("reviews:read")
    )
    |> FastestMCP.add_prompt("address_feedback", &Handlers.address_feedback_prompt/2,
      title: "Address review feedback",
      description: "Work through the open threads on a review and reply to each one.",
      arguments: [%{name: "review", description: "Review slug or URL", required: true}],
      authorization: Authorization.require_scopes("reviews:read")
    )
  end

  # ChatGPT reads `securitySchemes` to know a tool needs sign-in (OpenAI's
  # plugin reference: "_meta" mirror).
  defp security(scope), do: %{"securitySchemes" => [%{"type" => "oauth2", "scopes" => [scope]}]}

  defp add_read_tools(server) do
    read = [
      annotations: %{readOnlyHint: true, destructiveHint: false, openWorldHint: false},
      meta: security("reviews:read"),
      authorization: Authorization.require_scopes("reviews:read")
    ]

    server
    |> FastestMCP.add_tool(
      "reviews_list",
      &Handlers.list_reviews/2,
      [
        title: "List reviews",
        description:
          "Lists reviews you can find again, newest activity first: reviews written or " <>
            "taken part in (a comment, a section decision, or a viewed hunk). A connector " <>
            "signed in with OAuth lists the whole account's reviews; an agent API token lists " <>
            "only its agent's. role: authored, involved, or all. status: open (open threads), " <>
            "updated (a new revision since you took part), or all. author: a handle. q: " <>
            "text in the title, description, or slug. Continue with next_cursor.",
        input_schema:
          object(
            %{
              "role" => %{"type" => "string", "enum" => Reviews.ReviewIndex.roles()},
              "status" => %{"type" => "string", "enum" => Reviews.ReviewIndex.statuses()},
              "author" => %{"type" => "string", "maxLength" => 255},
              "q" => %{"type" => "string", "maxLength" => 500},
              "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => Paging.max_limit()},
              "cursor" => cursor_prop(),
              "max_bytes" => max_bytes_prop()
            },
            []
          )
      ] ++ read
    )
    |> FastestMCP.add_tool(
      "search",
      &Handlers.search/2,
      [
        title: "Search reviews",
        description:
          "Searches the reviews this account owns by title, description, or slug. Returns " <>
            "results with id, title, and url; pass an id to fetch. A blank query lists the " <>
            "newest reviews.",
        input_schema: object(%{"query" => %{"type" => "string", "maxLength" => 500}}, ["query"]),
        output_schema: %{
          "type" => "object",
          "properties" => %{
            "results" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "properties" => %{
                  "id" => %{"type" => "string"},
                  "title" => %{"type" => "string"},
                  "url" => %{"type" => "string"}
                },
                "required" => ["id", "title", "url"]
              }
            }
          },
          "required" => ["results"]
        }
      ] ++ read
    )
    |> FastestMCP.add_tool(
      "fetch",
      &Handlers.fetch/2,
      [
        title: "Fetch review",
        description:
          "Returns one review by the id search returned (its slug): title, url, " <>
            "description, and open feedback threads as Markdown.",
        input_schema:
          object(
            %{
              "id" => %{"type" => "string", "maxLength" => 2048, "description" => "Review slug."}
            },
            ["id"]
          ),
        output_schema: %{
          "type" => "object",
          "properties" => %{
            "id" => %{"type" => "string"},
            "title" => %{"type" => "string"},
            "text" => %{"type" => "string"},
            "url" => %{"type" => "string"},
            "metadata" => %{"type" => "object"}
          },
          "required" => ["id", "title", "text", "url"]
        }
      ] ++ read
    )
    |> FastestMCP.add_tool(
      "reviews_whoami",
      &Handlers.whoami/2,
      [
        title: "Who am I",
        description:
          "Returns the Reviews identity behind this connection's token (human or agent) " <>
            "and whether write tools are enabled.",
        input_schema: object(%{})
      ] ++ read
    )
    |> FastestMCP.add_tool(
      "reviews_get_review",
      &Handlers.get_review/2,
      [
        title: "Get review",
        description:
          "Returns a review's title, URL, description, thread counts, packet outline " <>
            "(section indexes and titles), and revisions with diff stats, newest first. " <>
            "Start here. Long reviews continue with next_cursor.",
        input_schema:
          object(%{
            "review" => review_prop(),
            "revision" => revision_prop(),
            "cursor" => cursor_prop(),
            "max_bytes" => max_bytes_prop()
          })
      ] ++ read
    )
    |> FastestMCP.add_tool(
      "reviews_get_packet_section",
      &Handlers.get_packet_section/2,
      [
        title: "Get packet section",
        description:
          "Returns one packet section's rows in reading order: Markdown prose and the diff " <>
            "of each hunk it narrates. A row with complete: false continues with next_cursor.",
        input_schema:
          object(
            %{
              "review" => review_prop(),
              "section_index" => %{
                "type" => "integer",
                "minimum" => 0,
                "description" => "Zero-based index from reviews_get_review."
              },
              "revision" => revision_prop(),
              "cursor" => cursor_prop(),
              "max_bytes" => max_bytes_prop()
            },
            ["review", "section_index"]
          )
      ] ++ read
    )
    |> FastestMCP.add_tool(
      "reviews_list_files",
      &Handlers.list_files/2,
      [
        title: "List files",
        description:
          "Lists the files changed in a revision with status, line counts, diff size, " <>
            "and open thread count, in path order. Continues with next_cursor.",
        input_schema:
          object(%{
            "review" => review_prop(),
            "revision" => revision_prop(),
            "cursor" => cursor_prop(),
            "max_bytes" => max_bytes_prop()
          })
      ] ++ read
    )
    |> FastestMCP.add_tool(
      "reviews_get_file_diff",
      &Handlers.get_file_diff/2,
      [
        title: "Get file diff",
        description:
          "Returns the unified diff of one file, at most max_bytes at a time. When " <>
            "next_offset is set, call again with that offset and the same revision.",
        input_schema:
          object(
            %{
              "review" => review_prop(),
              "path" => %{"type" => "string", "maxLength" => 4096},
              "revision" => revision_prop(),
              "offset" => %{"type" => "integer", "minimum" => 0},
              "max_bytes" => max_bytes_prop()
            },
            ["review", "path"]
          )
      ] ++ read
    )
    |> FastestMCP.add_tool(
      "reviews_list_threads",
      &Handlers.list_threads/2,
      [
        title: "List threads",
        description:
          "Lists review feedback threads with their first comments, projected onto a " <>
            "revision (latest by default). line is null when the thread's line is outdated. " <>
            "Defaults to open threads. When comments_complete is false, read the thread with " <>
            "reviews_get_thread.",
        input_schema:
          object(%{
            "review" => review_prop(),
            "revision" => revision_prop(),
            "status" => %{"type" => "string", "enum" => ["open", "resolved", "all"]},
            "path" => %{"type" => "string", "maxLength" => 4096},
            "limit" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => Paging.max_limit()
            },
            "cursor" => cursor_prop(),
            "max_bytes" => max_bytes_prop()
          })
      ] ++ read
    )
    |> FastestMCP.add_tool(
      "reviews_get_thread",
      &Handlers.get_thread/2,
      [
        title: "Get thread",
        description:
          "Returns one thread and all of its comments in order, projected onto a revision " <>
            "(latest by default). Long threads and comments continue with next_cursor.",
        input_schema:
          object(
            %{
              "review" => review_prop(),
              "thread_id" => %{"type" => "integer", "minimum" => 1},
              "revision" => revision_prop(),
              "cursor" => cursor_prop(),
              "max_bytes" => max_bytes_prop()
            },
            ["review", "thread_id"]
          )
      ] ++ read
    )
  end

  defp add_write_tools(server, writes?) do
    write = fn scope, idempotent? ->
      [
        enabled: writes?,
        meta: security(scope),
        annotations: %{
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: idempotent?,
          openWorldHint: false
        },
        authorization: Authorization.require_scopes(scope)
      ]
    end

    push_props = %{
      "raw_diff" => %{
        "type" => "string",
        "minLength" => 1,
        "description" => "Unified diff, as `git diff` prints it."
      },
      "packet" => packet_schema(),
      "branch_name" => %{"type" => "string", "maxLength" => 255},
      "base_sha" => %{"type" => "string", "maxLength" => 64}
    }

    server
    |> FastestMCP.add_tool(
      "reviews_create_review",
      &Handlers.create_review/2,
      [
        title: "Create review",
        description:
          "Publishes a new review from a unified diff and an optional packet, as the " <>
            "token's identity. Anyone with the returned link can view it. Not retried " <>
            "automatically: after a timeout, ask the user before creating it again.",
        input_schema:
          object(
            Map.merge(push_props, %{
              # reviews.title is varchar(255).
              "title" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
              "description" => %{"type" => "string", "maxLength" => 20_000}
            }),
            ["title", "raw_diff"]
          )
      ] ++ write.("reviews:write", false)
    )
    |> FastestMCP.add_tool(
      "reviews_append_revision",
      &Handlers.append_revision/2,
      [
        title: "Append revision",
        description:
          "Uploads a new revision (patchset) of a review you own, with its full diff and " <>
            "optional packet. Check reviews_get_review before retrying after a timeout.",
        input_schema: object(Map.put(push_props, "review", review_prop()), ["review", "raw_diff"])
      ] ++ write.("reviews:write", false)
    )
    |> FastestMCP.add_tool(
      "reviews_post_comment",
      &Handlers.post_comment/2,
      [
        title: "Post comment",
        description:
          "Publishes a comment right away. Pass thread_id to reply to a thread, or path " <>
            "and line (a changed or context line of the revision's diff) to start one. " <>
            "Comments cannot be edited. List threads before retrying after a timeout.",
        input_schema:
          object(
            %{
              "review" => review_prop(),
              "body" => %{"type" => "string", "minLength" => 1, "maxLength" => 20_000},
              "thread_id" => %{"type" => "integer", "minimum" => 1},
              "path" => %{"type" => "string", "maxLength" => 4096},
              "line" => %{"type" => "integer", "minimum" => 1},
              "side" => %{"type" => "string", "enum" => ["old", "new"]},
              "revision" => revision_prop()
            },
            ["review", "body"]
          )
      ] ++ write.("comments:write", false)
    )
    |> FastestMCP.add_tool(
      "reviews_update_thread_status",
      &Handlers.update_thread_status/2,
      [
        title: "Resolve or reopen thread",
        description: "Marks a thread resolved or reopens it, as the token's identity.",
        input_schema:
          object(
            %{
              "review" => review_prop(),
              "thread_id" => %{"type" => "integer", "minimum" => 1},
              "status" => %{"type" => "string", "enum" => ["open", "resolved"]}
            },
            ["review", "thread_id", "status"]
          )
      ] ++ write.("threads:write", true)
    )
  end

  defp object(properties, required \\ ["review"]) do
    required = Enum.filter(required, &Map.has_key?(properties, &1))

    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp review_prop do
    %{
      "type" => "string",
      "maxLength" => 2048,
      "description" => "Review slug (k7m2qz) or URL (https://<host>/r/k7m2qz)."
    }
  end

  defp revision_prop do
    %{
      "type" => "integer",
      "minimum" => 1,
      "description" => "Revision (patchset) number. Defaults to the latest."
    }
  end

  defp cursor_prop do
    %{
      "type" => "string",
      "maxLength" => 64,
      "pattern" => "^[a-z][0-9.]*$",
      "description" =>
        "next_cursor from the previous page, unchanged. An opaque string; send it with the same revision."
    }
  end

  defp max_bytes_prop do
    %{
      "type" => "integer",
      "minimum" => Paging.min_max_bytes(),
      "maximum" => Paging.max_bytes_limit(),
      "description" =>
        "Most bytes this result may take, metadata included. Default #{Paging.default_max_bytes()}."
    }
  end

  # Mirrors the CLI's packet validation (cli/src/packet.rs).
  defp packet_schema do
    markdown_row = %{
      "type" => "object",
      "properties" => %{"kind" => %{"const" => "markdown"}, "body" => %{"type" => "string"}},
      "required" => ["kind", "body"]
    }

    hunk_row = %{
      "type" => "object",
      "properties" => %{
        "kind" => %{"const" => "hunk"},
        "path" => %{"type" => "string", "minLength" => 1},
        "hunk_index" => %{"type" => "integer", "minimum" => 1},
        "line_start" => %{"type" => "integer", "minimum" => 1},
        "line_end" => %{"type" => "integer", "minimum" => 1}
      },
      "required" => ["kind", "path", "hunk_index"]
    }

    %{
      "type" => "object",
      "description" =>
        "Review packet JSON: sections in reading order, each with markdown and hunk rows. " <>
          "hunk_index is 1-based within the file's diff.",
      "properties" => %{
        "title" => %{"type" => "string", "minLength" => 1},
        "summary" => %{"type" => "string"},
        "sections" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "title" => %{"type" => "string", "minLength" => 1},
              "rows" => %{"type" => "array", "items" => %{"oneOf" => [markdown_row, hunk_row]}}
            },
            "required" => ["title", "rows"]
          }
        }
      },
      "required" => ["title", "sections"]
    }
  end
end
