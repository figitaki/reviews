defmodule ReviewsWeb.MCPTest do
  use ReviewsWeb.ConnCase, async: true

  alias Reviews.Accounts
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads
  alias ReviewsWeb.MCP.Server

  # Two files; the second has a multi-byte line so byte paging has to respect
  # UTF-8 boundaries.
  @diff_v1 """
  diff --git a/lib/a.ex b/lib/a.ex
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -1,3 +1,3 @@
   defmodule A do
  -  def a, do: :old
  +  def a, do: :new
   end
  @@ -10,2 +10,3 @@
   # tail
  +# added
   # end
  diff --git a/docs/b.md b/docs/b.md
  --- a/docs/b.md
  +++ b/docs/b.md
  @@ -1,2 +1,4 @@
   # Notes
  +Ünïcödé line one — with dashes
  +Second line ✓ with a check
   end
  """

  @diff_v2 """
  diff --git a/lib/a.ex b/lib/a.ex
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -1,3 +1,3 @@
   defmodule A do
  -  def a, do: :old
  +  def a, do: :newer
   end
  """

  setup do
    owner = user_fixture("owner")

    {:ok, agent} =
      Accounts.create_agent_identity(owner, %{handle: "codex", display_name: "Codex"})

    {:ok, _token, owner_token} = Accounts.mint_token(owner, %{"name" => "owner"})

    {:ok, _token, agent_token} =
      Accounts.mint_token(owner, %{name: "agent", identity_id: agent.id})

    stranger = user_fixture("stranger")
    {:ok, _token, stranger_token} = Accounts.mint_token(stranger, %{"name" => "stranger"})

    packet = %{
      "title" => "Packet",
      "summary" => "Two sections",
      "sections" => [
        %{
          "title" => "Code",
          "rows" => [
            %{"kind" => "markdown", "body" => "Intro prose."},
            %{"kind" => "hunk", "path" => "lib/a.ex", "hunk_index" => 1},
            %{"kind" => "hunk", "path" => "lib/a.ex", "hunk_index" => 2}
          ]
        },
        %{
          "title" => "Docs",
          "rows" => [%{"kind" => "hunk", "path" => "docs/b.md", "hunk_index" => 1}]
        }
      ]
    }

    {:ok, %{review: review}} =
      ReviewsContext.create_review_with_initial_patchset(owner, %{
        title: "Owned review",
        raw_diff: @diff_v1,
        packet: packet
      })

    %{
      owner: owner,
      agent: agent,
      review: review,
      owner_token: owner_token,
      agent_token: agent_token,
      stranger_token: stranger_token
    }
  end

  describe "HTTP endpoint" do
    test "rejects requests without a valid token", %{conn: conn} do
      conn = mcp_request(conn, "tools/list")
      assert conn.status == 401
      assert [_challenge] = get_resp_header(conn, "www-authenticate")

      conn = build_conn() |> auth("rev_not-a-token") |> mcp_request("tools/list")
      assert conn.status == 401
    end

    test "acts as the token's identity, not the account's human identity", %{
      conn: conn,
      agent_token: agent_token
    } do
      conn = conn |> auth(agent_token) |> mcp_request("tools/call", %{"name" => "reviews_whoami"})

      assert %{"result" => %{"structuredContent" => %{"identity" => identity}}} =
               json_response(conn, 200)

      assert %{"kind" => "agent", "handle" => "codex"} = identity
      assert get_resp_header(conn, "cache-control") |> Enum.any?(&(&1 =~ "no-store"))
    end

    test "stops accepting a token as soon as it is revoked", %{conn: conn, owner: owner} do
      {:ok, token, raw} = Accounts.mint_token(owner, %{"name" => "revoke-me"})

      assert build_conn() |> auth(raw) |> mcp_request("tools/list") |> json_response(200)

      :ok = Accounts.revoke_token(owner, token.id)
      assert (conn |> auth(raw) |> mcp_request("tools/list")).status == 401
    end

    @tag :capture_log
    test "rejects other hosts", %{conn: conn, owner_token: token} do
      conn = %{auth(conn, token) | host: "evil.example"} |> mcp_request("tools/list", %{}, nil)
      assert conn.status == 403
    end

    test "caps MCP bodies below the CLI upload limit", %{conn: conn, owner_token: token} do
      big = String.duplicate("x", 4_100_000)

      assert_error_sent 413, fn ->
        conn
        |> auth(token)
        |> mcp_request("tools/call", %{"name" => "reviews_whoami", "pad" => big})
      end

      # The same body size is still fine for the CLI's REST upload path.
      conn =
        build_conn()
        |> auth(token)
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/reviews", JSON.encode!(%{title: "Big", raw_diff: @diff_v1, pad: big}))

      assert conn.status == 201
    end
  end

  describe "read tools" do
    test "scope reviews to the owning account", ctx do
      assert %{slug: slug, title: "Owned review", revision: 1} =
               call!(ctx.agent_token, "reviews_get_review", %{
                 "review" => "https://reviews.example/r/#{ctx.review.slug}/changes"
               })

      assert slug == ctx.review.slug

      foreign = call(ctx.stranger_token, "reviews_get_review", %{"review" => ctx.review.slug})
      unknown = call(ctx.stranger_token, "reviews_get_review", %{"review" => "nosuchslug"})

      assert error_text(foreign) =~ "is owned by this account"

      assert error_text(foreign) ==
               String.replace(error_text(unknown), "nosuchslug", ctx.review.slug)
    end

    test "page a file diff on UTF-8 boundaries and pin continuations to a revision", ctx do
      {:ok, _} = ReviewsContext.append_patchset(ctx.review, ctx.agent, %{raw_diff: @diff_v2})

      [full] =
        for f <- ReviewsContext.parse_diff_files(@diff_v1), f.path == "docs/b.md", do: f.raw_diff

      # Revision 1 stays readable after revision 2 lands.
      pages = collect_pages(ctx.owner_token, ctx.review.slug, "docs/b.md", 1, 0, [])
      assert length(pages) >= 2
      assert Enum.all?(pages, &String.valid?/1)
      assert Enum.join(pages) == full

      # Revision 2 does not touch docs/b.md, so the latest default reports it.
      latest =
        call(ctx.owner_token, "reviews_get_file_diff", %{
          "review" => ctx.review.slug,
          "path" => "docs/b.md"
        })

      assert error_text(latest) =~ "No file"

      unpinned =
        call(ctx.owner_token, "reviews_get_file_diff", %{
          "review" => ctx.review.slug,
          "path" => "lib/a.ex",
          "offset" => 5
        })

      assert error_text(unpinned) =~ "Pass the revision"
    end

    test "byte windows never split a UTF-8 sequence" do
      text = String.duplicate("é✓", 50)

      for max <- [1, 2, 3, 4, 5, 7, 11] do
        chunks = take_all(text, 0, max, [])
        assert Enum.join(chunks) == text
        assert Enum.all?(chunks, &(&1 != "" and String.valid?(&1)))
      end

      assert {:error, _} = ReviewsWeb.MCP.Handlers.take_bytes(text, 1, 10)
    end

    test "cut packet sections to the byte budget and say so", ctx do
      section =
        call!(ctx.owner_token, "reviews_get_packet_section", %{
          "review" => ctx.review.slug,
          "section_index" => 0
        })

      assert [%{kind: "markdown", body: "Intro prose."}, h1, h2] = section.rows
      assert h1.diff =~ "+  def a, do: :new"
      assert h2.diff =~ "+# added"
      refute section.truncated

      # Room for the prose and the first hunk only: the second keeps its place
      # in the reading order but loses its diff.
      cut =
        call!(ctx.owner_token, "reviews_get_packet_section", %{
          "review" => ctx.review.slug,
          "section_index" => 0,
          "max_bytes" => byte_size("Intro prose.") + byte_size(h1.diff) + 1
        })

      assert [_, %{diff: d1}, %{diff: nil, path: "lib/a.ex", hunk_index: 2}] = cut.rows
      assert d1 == h1.diff
      assert cut.truncated
    end

    test "list threads projected onto the requested revision", ctx do
      {:ok, _} =
        Threads.publish_comment(ctx.review, ctx.owner, %{
          "file_path" => "docs/b.md",
          "side" => "new",
          "body" => "Why the check mark?",
          "thread_anchor" => %{
            "granularity" => "line",
            "line_number_hint" => 3,
            "line_text" => "Second line ✓ with a check"
          }
        })

      {:ok, _} = ReviewsContext.append_patchset(ctx.review, ctx.agent, %{raw_diff: @diff_v2})

      on_v1 =
        call!(ctx.agent_token, "reviews_list_threads", %{
          "review" => ctx.review.slug,
          "revision" => 1
        })

      assert [%{line: 3, anchor_status: "current", originating_revision: 1}] = on_v1.threads

      # docs/b.md is gone from revision 2, so the thread is outdated there.
      on_v2 = call!(ctx.agent_token, "reviews_list_threads", %{"review" => ctx.review.slug})
      assert on_v2.revision == 2

      assert [%{line: nil, anchor_status: "outdated", line_text: "Second line ✓ with a check"}] =
               on_v2.threads

      assert %{threads: []} =
               call!(ctx.agent_token, "reviews_list_threads", %{
                 "review" => ctx.review.slug,
                 "status" => "resolved"
               })
    end

    test "feedback resource renders open threads as Markdown", ctx do
      {:ok, _} =
        Threads.publish_comment(ctx.review, ctx.owner, %{
          "file_path" => "lib/a.ex",
          "side" => "new",
          "body" => "Rename this.",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 2}
        })

      markdown =
        FastestMCP.read_resource!(Server, "reviews://#{ctx.review.slug}/feedback",
          auth_input: bearer(ctx.agent_token)
        )

      %FastestMCP.Resources.Result{contents: [%{content: text, mime_type: "text/markdown"}]} =
        markdown

      assert text =~ "## Thread"
      assert text =~ "`lib/a.ex:2`"
      assert text =~ "Rename this."

      assert {:error, %{code: :not_found}} =
               FastestMCP.read_resource(Server, "reviews://#{ctx.review.slug}/feedback",
                 auth_input: bearer(ctx.stranger_token)
               )
    end
  end

  describe "write tools" do
    test "start a thread on a line of the chosen revision, attributed to the token", ctx do
      {:ok, _} = ReviewsContext.append_patchset(ctx.review, ctx.agent, %{raw_diff: @diff_v2})

      out =
        call!(ctx.agent_token, "reviews_post_comment", %{
          "review" => ctx.review.slug,
          "revision" => 1,
          "path" => "docs/b.md",
          "line" => 2,
          "body" => "Spell this in ASCII."
        })

      [thread] = Threads.list_published_threads(ctx.review.id)
      assert thread.id == out.thread_id
      assert thread.anchor["line_text"] == "Ünïcödé line one — with dashes"
      assert hd(thread.comments).author_id == ctx.agent.id
      v1 = Enum.find(ReviewsContext.list_patchsets(ctx.review), &(&1.number == 1))
      assert thread.originating_patchset_id == v1.id

      reply =
        call!(ctx.owner_token, "reviews_post_comment", %{
          "review" => ctx.review.slug,
          "thread_id" => thread.id,
          "body" => "Done."
        })

      assert reply.thread_id == thread.id
      assert reply.path == "docs/b.md"
    end

    test "refuse lines outside the diff and threads of other reviews without writing", ctx do
      outside =
        call(ctx.owner_token, "reviews_post_comment", %{
          "review" => ctx.review.slug,
          "path" => "lib/a.ex",
          "line" => 7,
          "body" => "Nope"
        })

      assert error_text(outside) =~ "not in revision 1"

      %{thread: other_thread} = Reviews.ThreadFixtures.thread_fixture()

      foreign_reply =
        call(ctx.owner_token, "reviews_post_comment", %{
          "review" => ctx.review.slug,
          "thread_id" => other_thread.id,
          "body" => "Hijack"
        })

      assert error_text(foreign_reply) =~ "No thread"
      assert Threads.list_published_threads(ctx.review.id) == []
    end

    test "create reviews as the token identity and reject packets that miss the diff", ctx do
      bad =
        call(ctx.agent_token, "reviews_create_review", %{
          "title" => "Bad packet",
          "raw_diff" => @diff_v2,
          "packet" => %{
            "title" => "P",
            "sections" => [
              %{
                "title" => "S",
                "rows" => [%{"kind" => "hunk", "path" => "lib/a.ex", "hunk_index" => 2}]
              }
            ]
          }
        })

      assert error_text(bad) =~ "lib/a.ex#2"

      out =
        call!(ctx.agent_token, "reviews_create_review", %{
          "title" => "Agent review",
          "raw_diff" => @diff_v2
        })

      assert ReviewsContext.get_review_by_slug(out.slug).author_id == ctx.agent.id

      assert %{revision: 2} =
               call!(ctx.owner_token, "reviews_append_revision", %{
                 "review" => out.slug,
                 "raw_diff" => @diff_v1
               })

      refused =
        call(ctx.stranger_token, "reviews_append_revision", %{
          "review" => out.slug,
          "raw_diff" => @diff_v1
        })

      assert error_text(refused) =~ "is owned by this account"
    end

    test "resolve and reopen threads", ctx do
      {:ok, %{thread: thread}} =
        Threads.publish_comment(ctx.review, ctx.owner, %{
          "file_path" => "lib/a.ex",
          "side" => "new",
          "body" => "Fix",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 2}
        })

      assert %{status: "resolved", resolved_by: %{handle: "codex"}} =
               call!(ctx.agent_token, "reviews_update_thread_status", %{
                 "review" => ctx.review.slug,
                 "thread_id" => thread.id,
                 "status" => "resolved"
               })
    end
  end

  ## Helpers

  defp take_all(text, offset, max, acc) do
    {:ok, chunk, next} = ReviewsWeb.MCP.Handlers.take_bytes(text, offset, max)
    if next, do: take_all(text, next, max, [chunk | acc]), else: Enum.reverse([chunk | acc])
  end

  defp collect_pages(token, slug, path, revision, offset, acc) do
    page =
      call!(token, "reviews_get_file_diff", %{
        "review" => slug,
        "path" => path,
        "revision" => revision,
        "offset" => offset,
        "max_bytes" => 100
      })

    acc = [page.diff | acc]

    case page.next_offset do
      nil -> Enum.reverse(acc)
      next -> collect_pages(token, slug, path, revision, next, acc)
    end
  end

  defp user_fixture(prefix) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: 2_000_000 + unique,
        username: "#{prefix}-#{unique}"
      })

    user
  end

  defp bearer(token), do: %{"authorization" => "Bearer " <> token}

  defp call(token, tool, args) do
    case FastestMCP.call_tool(Server, tool, args, auth_input: bearer(token)) do
      {:ok, value} -> value
      {:error, error} -> error
    end
  end

  defp call!(token, tool, args),
    do: FastestMCP.call_tool!(Server, tool, args, auth_input: bearer(token))

  defp error_text(%FastestMCP.Tools.Result{is_error: true, content: content}) do
    case content do
      text when is_binary(text) -> text
      [%{"text" => text} | _] -> text
      [%{text: text} | _] -> text
    end
  end

  defp error_text(other), do: flunk("expected an error result, got: #{inspect(other)}")

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  # One request of MCP protocol version 2026-07-28, as FastestMCP's Phoenix
  # guide sends it.
  defp mcp_request(conn, method, params \\ %{}, host \\ "localhost") do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => method,
      "params" => Map.put(params, "_meta", meta)
    }

    conn = if name = params["name"], do: put_req_header(conn, "mcp-name", name), else: conn
    conn = if host, do: %{conn | host: host}, else: conn

    conn
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", "2026-07-28")
    |> put_req_header("mcp-method", method)
    |> post("/mcp", JSON.encode!(body))
  end
end
