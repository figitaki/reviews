defmodule ReviewsWeb.MCPTest do
  use ReviewsWeb.ConnCase, async: true

  alias Reviews.Accounts
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads
  alias ReviewsWeb.MCP.{Budget, Server}

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

  test "REST and MCP expose the same public comment and identity metadata", ctx do
    attribution = %{
      "provider" => "poppy",
      "client_id" => "https://agent.example/client.json",
      "owner_username" => "owner",
      "agent_id_claimed" => "private-agent",
      "access_token_dpop_key" => "private-key-thumbprint",
      "subject" => "private-subject"
    }

    {:ok, %{thread: thread, comment: comment}} =
      Threads.publish_comment(ctx.review, ctx.owner, %{
        "file_path" => "lib/a.ex",
        "side" => "new",
        "body" => "Check this",
        "thread_anchor" => %{
          "granularity" => "line",
          "line_number_hint" => 2,
          "line_text" => "  def a, do: :new"
        }
      })

    comment |> Ecto.Changeset.change(attribution: attribution) |> Reviews.Repo.update!()
    rest = get(build_conn(), "/api/v1/reviews/#{ctx.review.slug}") |> json_response(200)
    [rest_thread] = rest["threads"]
    [rest_comment] = rest_thread["comments"]
    assert rest_comment["id"] == comment.id
    assert rest_comment["attribution"]["token_binding"] == "dpop"
    assert rest_comment["attribution"]["agent_id_claimed"] == true
    refute JSON.encode!(rest) =~ "private-"
    assert rest_thread["path"] == rest_thread["file_path"]
    assert rest_thread["line"] == rest_thread["line_hint"]
    assert rest_thread["anchor_status"] == "current"
    assert rest_thread["originating_revision"] == 1

    {_bytes, result} =
      http_call(ctx.owner_token, "reviews_get_thread", %{
        "review" => ctx.review.slug,
        "thread_id" => thread.id
      })

    [mcp_comment] = result["comments"]
    assert mcp_comment["id"] == rest_comment["id"]
    assert mcp_comment["attribution"] == rest_comment["attribution"]

    assert mcp_comment["author"] ==
             Map.take(rest_comment["author"], ["id", "kind", "handle", "display_name"])

    {:ok, _} = ReviewsContext.append_patchset(ctx.review, %{raw_diff: @diff_v2})
    latest = get(build_conn(), "/api/v1/reviews/#{ctx.review.slug}") |> json_response(200)
    [outdated] = latest["threads"]
    assert outdated["anchor_status"] == "outdated"
    assert outdated["line_hint"] == nil
    assert outdated["originating_revision"] == 1
    assert outdated["line_text"] == "  def a, do: :new"
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

    test "page a long file diff within max_bytes, counting the whole response", ctx do
      # About 30 KB of multi-byte lines, so pages must cut between characters.
      lines = for n <- 1..600, do: "+Ünïcödé line #{n} — ✓\n"

      raw =
        "diff --git a/big.md b/big.md\n--- a/big.md\n+++ b/big.md\n@@ -0,0 +1,600 @@\n" <>
          Enum.join(lines)

      slug = review_fixture(ctx.owner, raw).slug

      pages =
        Stream.unfold(0, fn
          nil ->
            nil

          offset ->
            {size, page} =
              http_call(ctx.owner_token, "reviews_get_file_diff", %{
                "review" => slug,
                "path" => "big.md",
                "revision" => 1,
                "offset" => offset,
                "max_bytes" => 2_000
              })

            assert size <= 2_000
            {page, page["next_offset"]}
        end)
        |> Enum.to_list()

      assert length(pages) > 10
      assert Enum.all?(pages, &String.valid?(&1["diff"]))
      [file] = ReviewsContext.parse_diff_files(raw)
      assert Enum.map_join(pages, & &1["diff"]) == file.raw_diff

      unpinned =
        call(ctx.owner_token, "reviews_get_file_diff", %{
          "review" => slug,
          "path" => "big.md",
          "offset" => 5
        })

      assert error_text(unpinned) =~ "Pass the revision"
    end

    test "keep old revisions readable after a new push", ctx do
      {:ok, _} = ReviewsContext.append_patchset(ctx.review, ctx.agent, %{raw_diff: @diff_v2})

      old =
        call!(ctx.owner_token, "reviews_get_file_diff", %{
          "review" => ctx.review.slug,
          "path" => "docs/b.md",
          "revision" => 1
        })

      assert old.diff =~ "Second line ✓"

      # Revision 2 does not touch docs/b.md, so the latest default reports it.
      latest =
        call(ctx.owner_token, "reviews_get_file_diff", %{
          "review" => ctx.review.slug,
          "path" => "docs/b.md"
        })

      assert error_text(latest) =~ "No file"
    end

    test "cut text without splitting a character or going over budget" do
      text = String.duplicate("é✓", 50)

      # 14 bytes is the cost of one "✓", the largest character here.
      for budget <- [14, 15, 20, 33, 50, 400] do
        chunks =
          Stream.unfold(0, fn
            nil -> nil
            offset -> Budget.fit_text(text, offset, budget)
          end)
          |> Enum.take(200)

        assert Enum.join(chunks) == text
        assert Enum.all?(chunks, &(&1 != "" and String.valid?(&1) and Budget.cost(&1) <= budget))
      end

      # Strict: when no whole character fits, nothing is returned.
      assert Budget.fit_text("✓", 0, 5) == {"", 0}
    end

    test "page packet sections row by row, continuing long prose", ctx do
      prose = String.duplicate("Prose with ünïcödé — ", 400)

      packet = %{
        "title" => "Long",
        "sections" => [
          %{
            "title" => "Only",
            "rows" => [
              %{"kind" => "markdown", "body" => prose},
              %{"kind" => "hunk", "path" => "lib/a.ex", "hunk_index" => 1},
              %{"kind" => "hunk", "path" => "lib/a.ex", "hunk_index" => 2}
            ]
          }
        ]
      }

      slug = review_fixture(ctx.owner, @diff_v1, packet).slug

      {pages, _} =
        Enum.reduce_while(1..50, {[], nil}, fn _, {acc, cursor} ->
          args = %{"review" => slug, "section_index" => 0, "revision" => 1, "max_bytes" => 2_000}
          args = if cursor, do: Map.put(args, "cursor", cursor), else: args
          {size, page} = http_call(ctx.owner_token, "reviews_get_packet_section", args)
          assert size <= 2_000

          if page["next_cursor"],
            do: {:cont, {[page | acc], page["next_cursor"]}},
            else: {:halt, {Enum.reverse([page | acc]), nil}}
        end)

      assert length(pages) > 5
      rows = Enum.flat_map(pages, & &1["rows"])
      body = rows |> Enum.filter(&(&1["row"] == 0)) |> Enum.map_join(& &1["body"])
      assert body == prose

      diff_of = fn row ->
        rows |> Enum.filter(&(&1["row"] == row)) |> Enum.map_join(& &1["diff"])
      end

      assert diff_of.(1) =~ "-  def a, do: :old\n+  def a, do: :new\n end"
      assert diff_of.(2) =~ "+# added"
      assert rows |> Enum.filter(&(&1["row"] == 2)) |> List.last() |> Map.get("complete")
    end

    test "page files, threads, and the comments of one thread", ctx do
      files =
        for n <- 1..40,
            do:
              "diff --git a/f#{n}.ex b/f#{n}.ex\n--- a/f#{n}.ex\n+++ b/f#{n}.ex\n@@ -1 +1 @@\n-a\n+b\n"

      review = review_fixture(ctx.owner, Enum.join(files))

      listed =
        page_all(ctx.owner_token, "reviews_list_files", %{"review" => review.slug}, "files")

      assert length(listed) == 40

      assert %{file_count: 40} =
               call!(ctx.owner_token, "reviews_list_files", %{"review" => review.slug})

      assert listed |> Enum.map(& &1["path"]) |> Enum.uniq() |> length() == 40

      # Bare positions are not cursors: the schema refuses them, and a
      # well-formed cursor of the wrong kind is refused by the tool.
      page = fn tool, cursor ->
        call(ctx.owner_token, tool, %{
          "review" => review.slug,
          "revision" => 1,
          "cursor" => cursor
        })
      end

      assert %FastestMCP.Error{code: :invalid_params} = page.("reviews_list_files", "12")

      assert %FastestMCP.Error{code: :invalid_params} =
               page.("reviews_list_threads", "0.10")

      assert error_text(page.("reviews_list_threads", "s3")) =~ "Invalid cursor"

      for n <- 1..6 do
        {:ok, _} =
          Threads.publish_comment(review, ctx.owner, %{
            "file_path" => "f#{n}.ex",
            "side" => "new",
            "body" => String.duplicate("Long note ✓ ", 150),
            "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 1}
          })
      end

      threads =
        page_all(
          ctx.owner_token,
          "reviews_list_threads",
          %{"review" => review.slug, "limit" => 4},
          "threads"
        )

      assert length(threads) == 6
      assert threads |> Enum.map(& &1["id"]) |> Enum.uniq() |> length() == 6
      assert Enum.all?(threads, &(&1["comments_complete"] == false))

      # The full comment is readable through reviews_get_thread in pieces.
      [first | _] = threads

      comments =
        page_all(
          ctx.owner_token,
          "reviews_get_thread",
          %{"review" => review.slug, "thread_id" => first["id"]},
          "comments"
        )

      # publish_comment trims the body.
      assert Enum.map_join(comments, & &1["body"]) ==
               String.trim(String.duplicate("Long note ✓ ", 150))

      assert length(comments) > 1

      # A cursor continues only the query it came from: another filter or
      # another thread refuses it instead of skipping or repeating items.
      open_page =
        call!(ctx.owner_token, "reviews_list_threads", %{
          "review" => review.slug,
          "revision" => 1,
          "limit" => 2
        })

      assert [_, _] = open_page.threads

      assert error_text(
               call(ctx.owner_token, "reviews_list_threads", %{
                 "review" => review.slug,
                 "revision" => 1,
                 "status" => "all",
                 "cursor" => open_page.next_cursor
               })
             ) =~ "Invalid cursor"

      [_, second | _] = threads

      thread_page =
        call!(ctx.owner_token, "reviews_get_thread", %{
          "review" => review.slug,
          "revision" => 1,
          "thread_id" => first["id"],
          "max_bytes" => 2_000
        })

      assert is_binary(thread_page.next_cursor)

      assert error_text(
               call(ctx.owner_token, "reviews_get_thread", %{
                 "review" => review.slug,
                 "revision" => 1,
                 "thread_id" => second["id"],
                 "cursor" => thread_page.next_cursor
               })
             ) =~ "Invalid cursor"
    end

    test "budget every row, including empty and missing ones", ctx do
      rows =
        for n <- 1..300 do
          if rem(n, 10) == 0,
            do: %{"kind" => "hunk", "path" => "nope.ex", "hunk_index" => n},
            else: %{"kind" => "markdown", "body" => ""}
        end

      packet = %{"title" => "Empty rows", "sections" => [%{"title" => "S", "rows" => rows}]}
      slug = review_fixture(ctx.owner, @diff_v1, packet).slug

      listed =
        page_all(
          ctx.owner_token,
          "reviews_get_packet_section",
          %{"review" => slug, "section_index" => 0},
          "rows"
        )

      assert Enum.map(listed, & &1["row"]) == Enum.to_list(0..299)
      assert listed |> Enum.filter(& &1["missing"]) |> length() == 30

      # Whatever budget is left after a row's metadata, an empty row comes
      # back once, complete, and paging never repeats a row.
      for max_bytes <- 2_000..2_040 do
        rows =
          page_all(
            ctx.owner_token,
            "reviews_get_packet_section",
            %{"review" => slug, "section_index" => 0, "max_bytes" => max_bytes},
            "rows"
          )

        assert Enum.map(rows, & &1["row"]) == Enum.to_list(0..299)
        assert Enum.all?(rows, & &1["complete"])
      end
    end

    test "return long paths whole, so they still select the file", ctx do
      # 253 characters and 1,003 bytes: within the column, past any short cap.
      path = String.duplicate("𝄞", 250) <> ".md"
      raw = "diff --git a/#{path} b/#{path}\n--- a/#{path}\n+++ b/#{path}\n@@ -1 +1 @@\n-a\n+b\n"
      slug = review_fixture(ctx.owner, raw).slug

      assert %{files: [%{path: ^path}], file_count: 1} =
               call!(ctx.owner_token, "reviews_list_files", %{"review" => slug})

      assert %{diff: diff} =
               call!(ctx.owner_token, "reviews_get_file_diff", %{"review" => slug, "path" => path})

      assert diff =~ "+b"
    end

    test "refuse a page whose header alone is over max_bytes", ctx do
      path = String.duplicate("✓", 255)
      raw = "diff --git a/#{path} b/#{path}\n--- a/#{path}\n+++ b/#{path}\n@@ -1 +1 @@\n-a\n+b\n"
      review = review_fixture(ctx.owner, raw)

      {:ok, %{thread: thread}} =
        Threads.publish_comment(review, ctx.owner, %{
          "file_path" => path,
          "side" => "new",
          "body" => "Short",
          "thread_anchor" => %{
            "granularity" => "line",
            "line_number_hint" => 1,
            "line_text" => String.duplicate("✓", 600)
          }
        })

      small =
        call(ctx.owner_token, "reviews_get_thread", %{
          "review" => review.slug,
          "thread_id" => thread.id,
          "max_bytes" => 2_000
        })

      assert error_text(small) =~ "max_bytes is too small"

      assert %{comments: [%{body: "Short"}]} =
               call!(ctx.owner_token, "reviews_get_thread", %{
                 "review" => review.slug,
                 "thread_id" => thread.id
               })
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

      # A thread with more comments than the resource shows says so.
      [thread] = Threads.list_published_threads(ctx.review.id)

      for n <- 1..21 do
        {:ok, _} =
          Threads.publish_comment(ctx.review, ctx.owner, %{
            "thread_id" => thread.id,
            "body" => "Reply #{n}",
            "file_path" => "(reply)",
            "side" => "new",
            "thread_anchor" => %{"granularity" => "line"}
          })
      end

      %FastestMCP.Resources.Result{contents: [%{content: longer}]} =
        FastestMCP.read_resource!(Server, "reviews://#{ctx.review.slug}/feedback",
          auth_input: bearer(ctx.agent_token)
        )

      assert longer =~ "reviews_get_thread (thread_id #{thread.id})"
      refute longer =~ "Reply 21"

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

      for {slice, message} <- [
            {%{"line_start" => 1}, "both line_start and line_end"},
            {%{"line_start" => 2, "line_end" => 9}, "outside the hunk"},
            {%{"line_start" => 3, "line_end" => 2}, "outside the hunk"}
          ] do
        row = Map.merge(%{"kind" => "hunk", "path" => "lib/a.ex", "hunk_index" => 1}, slice)

        sliced =
          call(ctx.agent_token, "reviews_create_review", %{
            "title" => "Bad slice",
            "raw_diff" => @diff_v2,
            "packet" => %{"title" => "P", "sections" => [%{"title" => "S", "rows" => [row]}]}
          })

        assert error_text(sliced) =~ message
      end

      # The hunk has four rows (context, -, +, context), so L1-L4 is the whole hunk.
      assert %{slug: _} =
               call!(ctx.agent_token, "reviews_create_review", %{
                 "title" => "Good slice",
                 "raw_diff" => @diff_v2,
                 "packet" => %{
                   "title" => "P",
                   "sections" => [
                     %{
                       "title" => "S",
                       "rows" => [
                         %{
                           "kind" => "hunk",
                           "path" => "lib/a.ex",
                           "hunk_index" => 1,
                           "line_start" => 2,
                           "line_end" => 4
                         }
                       ]
                     }
                   ]
                 }
               })

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

    test "require packets to cover every changed line exactly once", ctx do
      create = fn rows ->
        call(ctx.agent_token, "reviews_create_review", %{
          "title" => "Coverage",
          "raw_diff" => @diff_v1,
          "packet" => %{"title" => "P", "sections" => [%{"title" => "S", "rows" => rows}]}
        })
      end

      hunk = fn path, i, extra ->
        Map.merge(%{"kind" => "hunk", "path" => path, "hunk_index" => i}, extra)
      end

      all = [hunk.("lib/a.ex", 1, %{}), hunk.("lib/a.ex", 2, %{}), hunk.("docs/b.md", 1, %{})]

      assert %{slug: _} = create.(all) |> then(&(&1 || flunk("no result")))

      missing = create.(Enum.take(all, 2))
      assert error_text(missing) =~ "changed line docs/b.md#1:L2 is not in any hunk row"

      repeated = create.(all ++ [hunk.("lib/a.ex", 1, %{"line_start" => 2, "line_end" => 2})])
      assert error_text(repeated) =~ "changed line lib/a.ex#1:L2 is covered 2 times"
    end

    test "count hunk rows starting with +++ or --- as changes", ctx do
      raw = """
      diff --git a/notes.md b/notes.md
      --- a/notes.md
      +++ b/notes.md
      @@ -1,2 +1,2 @@
       keep
      --- note
      +++ x
      """

      create = fn extra ->
        row = Map.merge(%{"kind" => "hunk", "path" => "notes.md", "hunk_index" => 1}, extra)

        call(ctx.agent_token, "reviews_create_review", %{
          "title" => "Dashes",
          "raw_diff" => raw,
          "packet" => %{"title" => "P", "sections" => [%{"title" => "S", "rows" => [row]}]}
        })
      end

      context_only = create.(%{"line_start" => 1, "line_end" => 1})
      assert error_text(context_only) =~ "changed line notes.md#1:L2 is not in any hunk row"
      assert error_text(context_only) =~ "changed line notes.md#1:L3 is not in any hunk row"

      assert %{slug: _} = create.(%{})
    end

    test "slice hunks around no-newline markers the way the CLI numbers rows", ctx do
      raw = """
      diff --git a/x.txt b/x.txt
      --- a/x.txt
      +++ b/x.txt
      @@ -1 +1 @@
      -old
      \\ No newline at end of file
      +new
      \\ No newline at end of file
      """

      rows = [
        %{
          "kind" => "hunk",
          "path" => "x.txt",
          "hunk_index" => 1,
          "line_start" => 1,
          "line_end" => 1
        },
        %{
          "kind" => "hunk",
          "path" => "x.txt",
          "hunk_index" => 1,
          "line_start" => 2,
          "line_end" => 2
        }
      ]

      %{slug: slug} =
        call!(ctx.agent_token, "reviews_create_review", %{
          "title" => "Markers",
          "raw_diff" => raw,
          "packet" => %{"title" => "P", "sections" => [%{"title" => "S", "rows" => rows}]}
        })

      %{rows: [first, second]} =
        call!(ctx.agent_token, "reviews_get_packet_section", %{
          "review" => slug,
          "section_index" => 0
        })

      assert first.diff =~ "-old\n\\ No newline at end of file"
      refute first.diff =~ "+new"
      assert second.diff =~ "+new\n\\ No newline at end of file"
      refute second.diff =~ "-old"
    end

    test "refuse titles longer than the column", ctx do
      assert {:error, %{code: :invalid_params}} =
               FastestMCP.call_tool(
                 Server,
                 "reviews_create_review",
                 %{"title" => String.duplicate("t", 256), "raw_diff" => @diff_v2},
                 auth_input: bearer(ctx.agent_token)
               )
    end

    test "resolve and reopen threads", ctx do
      {:ok, %{thread: thread}} =
        Threads.publish_comment(ctx.review, ctx.owner, %{
          "file_path" => "lib/a.ex",
          "side" => "new",
          "body" => "Fix",
          "thread_anchor" => %{"granularity" => "line", "line_number_hint" => 2}
        })

      refused =
        call(ctx.stranger_token, "reviews_update_thread_status", %{
          "review" => ctx.review.slug,
          "thread_id" => thread.id,
          "status" => "resolved"
        })

      # MCP keeps its owner-only limit until it moves to the shared rules (#176).
      assert error_text(refused) =~ "is owned by this account"
      assert [%{status: "open"}] = Threads.list_published_threads(ctx.review.id)

      assert %{status: "resolved", resolved_by: %{handle: "codex"}} =
               call!(ctx.agent_token, "reviews_update_thread_status", %{
                 "review" => ctx.review.slug,
                 "thread_id" => thread.id,
                 "status" => "resolved"
               })
    end
  end

  ## Helpers

  # Calls a tool until next_cursor runs out, at the smallest budget, checking
  # each complete HTTP response against it. Returns the concatenated `key` lists.
  defp page_all(token, tool, args, key) do
    args = Map.merge(%{"revision" => 1, "max_bytes" => 2_000}, args)

    Stream.unfold(:start, fn
      nil ->
        nil

      cursor ->
        args = if cursor == :start, do: args, else: Map.put(args, "cursor", cursor)
        {size, page} = http_call(token, tool, args)
        assert size <= 2_000, "#{tool} returned #{size} bytes"
        refute page["isError"]
        next = page["next_cursor"]
        # Opaque: a string no client could read as a JSON number.
        assert is_nil(next) or (is_binary(next) and not match?({:ok, _}, JSON.decode(next)))
        {page[key], next}
    end)
    |> Enum.take(100)
    |> Enum.concat()
  end

  defp review_fixture(owner, raw_diff, packet \\ nil) do
    {:ok, %{review: review}} =
      ReviewsContext.create_review_with_initial_patchset(owner, %{
        title: "Fixture",
        raw_diff: raw_diff,
        packet: packet
      })

    review
  end

  # One tools/call over HTTP. Returns the response body size and the
  # structured content.
  defp http_call(token, tool, args) do
    conn =
      build_conn()
      |> auth(token)
      |> mcp_request("tools/call", %{"name" => tool, "arguments" => args})

    body = conn.resp_body
    assert conn.status == 200, body
    %{"result" => result} = JSON.decode!(body)
    refute result["isError"], inspect(result["content"])
    {byte_size(body), result["structuredContent"]}
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
