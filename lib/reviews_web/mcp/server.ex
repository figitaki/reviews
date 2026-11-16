defmodule ReviewsWeb.MCP.Server do
  @moduledoc """
  Hosted MCP server (Streamable HTTP at `/mcp`), built on FastestMCP.

  Callers authenticate with an existing Reviews API token as a bearer token,
  the same token the CLI uses. The token's identity is the actor for every
  call, so agent identities keep their attribution. Tokens have no scope model
  yet, so every valid token holds all scopes below; the server-wide writes flag
  is the only way to make the endpoint read-only.

  The endpoint and its write tools are off unless configured:

      config :reviews, :mcp, enabled: true, writes_enabled: true

  See `docs/MCP.md`.
  """
  use FastestMCP.ServerModule, otp_app: :reviews

  alias FastestMCP.Authorization
  alias Reviews.Accounts
  alias ReviewsWeb.MCP.Handlers

  @scopes ["reviews:read", "reviews:write", "threads:write"]

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
  session, so a revoked token stops working on its next call.
  """
  def authenticate(input, _ctx) do
    with "Bearer " <> token <- input["authorization"] || "",
         {:ok, %{user: user, identity: identity}} <- Accounts.authenticate_token(token) do
      {:ok,
       %{
         principal: %{"identity_id" => identity.id, "user_id" => user.id},
         scopes: @scopes
       }}
    else
      _ -> {:error, :unauthorized}
    end
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
        max_requests_per_second: 5.0,
        burst_capacity: 20,
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

  defp add_read_tools(server) do
    read = [
      annotations: %{readOnlyHint: true, openWorldHint: false},
      authorization: Authorization.require_scopes("reviews:read")
    ]

    server
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
          "Returns a review's title, URL, revisions with diff stats, packet outline " <>
            "(section indexes and titles), and thread counts. Start here.",
        input_schema: object(%{"review" => review_prop(), "revision" => revision_prop()})
      ] ++ read
    )
    |> FastestMCP.add_tool(
      "reviews_get_packet_section",
      &Handlers.get_packet_section/2,
      [
        title: "Get packet section",
        description:
          "Returns one packet section's rows in reading order: Markdown prose and the diff " <>
            "of each hunk it narrates. Rows past max_bytes come back without their diff.",
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
            "and open thread count.",
        input_schema: object(%{"review" => review_prop(), "revision" => revision_prop()})
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
          "Lists review feedback threads with their comments, projected onto a revision " <>
            "(latest by default). line is null when the thread's line is outdated. " <>
            "Defaults to open threads.",
        input_schema:
          object(%{
            "review" => review_prop(),
            "revision" => revision_prop(),
            "status" => %{"type" => "string", "enum" => ["open", "resolved", "all"]},
            "path" => %{"type" => "string", "maxLength" => 4096},
            "limit" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => Handlers.thread_limit()
            },
            "cursor" => %{"type" => "string", "maxLength" => 20}
          })
      ] ++ read
    )
  end

  defp add_write_tools(server, writes?) do
    write = fn scope, idempotent? ->
      [
        enabled: writes?,
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
              "title" => %{"type" => "string", "minLength" => 1, "maxLength" => 300},
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
      ] ++ write.("threads:write", false)
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

  defp max_bytes_prop do
    %{
      "type" => "integer",
      "minimum" => 100,
      "maximum" => Handlers.max_bytes_limit(),
      "description" =>
        "Byte budget for diff and prose text. Default #{Handlers.default_max_bytes()}."
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
