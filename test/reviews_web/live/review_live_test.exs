defmodule ReviewsWeb.ReviewLiveTest do
  use ReviewsWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Reviews.Accounts
  alias Reviews.PacketHunkViews
  alias Reviews.ReviewView
  alias Reviews.Reviews, as: ReviewsCtx
  alias Reviews.Threads

  defp snapshot!(review) do
    {:ok, snapshot} = ReviewView.snapshot(review, nil, [])
    snapshot
  end

  defp snapshot_hunk(review, path, hunk_index) do
    review
    |> snapshot!()
    |> Map.fetch!(:hunks_by_path)
    |> Map.fetch!(path)
    |> Enum.find(&(&1.hunk_index == hunk_index))
  end

  defp hunk_view_params(review, path, hunk_index, extra) do
    hunk = snapshot_hunk(review, path, hunk_index)

    Map.merge(
      %{
        "file_path" => hunk.file_path,
        "row_ref" => hunk.row_ref,
        "hunk_fingerprint" => hunk.hunk_fingerprint,
        "hunk_index" => hunk.hunk_index,
        "line_start" => hunk.line_start,
        "line_end" => hunk.line_end
      },
      extra
    )
  end

  defp grouped_hunk_view_params(review, path, hunk_id) do
    attrs =
      review
      |> snapshot!()
      |> Map.fetch!(:hunks_by_path)
      |> Map.fetch!(path)
      |> Enum.map(
        &%{
          file_path: &1.file_path,
          row_ref: &1.row_ref,
          hunk_fingerprint: &1.hunk_fingerprint,
          hunk_index: &1.hunk_index,
          line_start: &1.line_start,
          line_end: &1.line_end
        }
      )

    %{"hunk_attrs" => JSON.encode!(attrs), "hunk_id" => hunk_id}
  end

  defp changes_hunk_id(review, path) do
    file = Enum.find(snapshot!(review).file_diffs, &(&1.path == path))
    "file-diff-#{file.id}"
  end

  defp seed!(_) do
    {:ok, author} =
      Accounts.upsert_from_github(%{
        github_id: 1234,
        username: "carey",
        email: "carey@example.com",
        avatar_url: nil
      })

    raw_diff = """
    diff --git a/lib/foo.ex b/lib/foo.ex
    --- a/lib/foo.ex
    +++ b/lib/foo.ex
    @@ -1,3 +1,3 @@
     defmodule Foo do
    -  def bar, do: :old
    +  def bar, do: :new
     end
    """

    {:ok, %{review: review}} =
      ReviewsCtx.create_review_with_initial_patchset(author, %{
        title: "Great change",
        description: "Make bar do :new",
        raw_diff: raw_diff
      })

    %{author: author, review: review}
  end

  describe "anonymous viewer" do
    setup :seed!

    test "current and historical review pages discourage indexing", %{review: review} do
      {:ok, _patchset} =
        ReviewsCtx.append_patchset(review, %{
          raw_diff: "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n"
        })

      for path <- [
            ~p"/r/#{review.slug}",
            ~p"/r/#{review.slug}/changes",
            ~p"/r/#{review.slug}?patchset=1",
            ~p"/r/#{review.slug}/changes?patchset=1"
          ] do
        conn = get(build_conn(), path)

        assert html_response(conn, 200)
        assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow, noarchive"]
      end
    end

    test "renders collapsed diff islands through the single Pierre header", %{
      conn: conn,
      review: review
    } do
      {:ok, view, html} = live(conn, ~p"/r/#{review.slug}")

      assert html =~ "Great change"
      assert html =~ "lib/foo.ex"

      assert has_element?(view, "#diff-files .review-hunk-card")
      refute has_element?(view, "#diff-files .review-hunk-summary")

      assert has_element?(
               view,
               ~s|[phx-hook="DiffRenderer"][data-file-path="lib/foo.ex"][data-hunk-expanded="false"]|
             )

      render_click(view, "toggle_hunk_diff", %{
        "hunk_id" => changes_hunk_id(review, "lib/foo.ex")
      })

      assert has_element?(
               view,
               ~s|[phx-hook="DiffRenderer"][data-file-path="lib/foo.ex"][data-hunk-expanded="true"]|
             )
    end

    test "tablet viewport keeps the diff layout unified", %{conn: conn, review: review} do
      {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}/changes")

      assert has_element?(view, ~s|#diff-style-toggle[data-tablet-query="(max-width: 1024px)"]|)
      assert has_element?(view, ~s|#diff-style-split[data-requires-wide="true"]|)
      assert has_element?(view, ~s|#diff-style-split[aria-pressed="true"]|)

      render_click(view, "select_diff_style", %{"style" => "unified", "viewport" => "tablet"})
      assert has_element?(view, ~s|#diff-style-unified[aria-pressed="true"]|)

      render_click(view, "select_diff_style", %{"style" => "split", "viewport" => "tablet"})
      assert has_element?(view, ~s|#diff-style-unified[aria-pressed="true"]|)

      render_click(view, "select_diff_style", %{"style" => "split", "viewport" => "wide"})
      assert has_element?(view, ~s|#diff-style-split[aria-pressed="true"]|)
    end

    test "renders a stored review packet above the diff", %{conn: conn, author: author} do
      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Packet change",
          raw_diff: """
          diff --git a/lib/packet.ex b/lib/packet.ex
          --- a/lib/packet.ex
          +++ b/lib/packet.ex
          @@ -1 +1 @@
          -old
          +new
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "summary" => "Read this first.",
            "sections" => [
              %{
                "title" => "Main change",
                "rows" => [
                  %{
                    "kind" => "markdown",
                    "body" =>
                      "### Main change\nPreserve packet JSON as the server contract.\n\nKeep packet.md editable."
                  },
                  %{
                    "kind" => "hunk",
                    "path" => "lib/packet.ex",
                    "hunk_index" => 1,
                    "line_start" => 1,
                    "line_end" => 2
                  },
                  %{"kind" => "markdown", "body" => "Run the smoke test."}
                ]
              }
            ]
          }
        })

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      view |> element("#review-guide-tick-0") |> render_click()
      html = render(view)

      assert has_element?(view, "#review-packet")
      assert has_element?(view, ".review-title.is-packet-title", "Packet walkthrough")
      assert has_element?(view, ".review-packet-lede", "Read this first.")
      assert has_element?(view, ".review-header-estimate", "1 min")
      assert has_element?(view, ".review-header-change-stat .review-change-stat-add", "+1")
      assert has_element?(view, ".review-header-change-stat .review-change-stat-del", "-1")
      assert has_element?(view, "#packet-section-0.is-open")

      assert has_element?(
               view,
               "#review-split-section-overview-0 .review-section-header-meta",
               "Light"
             )

      assert has_element?(view, "#review-split-section-overview-0 .review-change-stat-add", "+1")
      assert has_element?(view, "#review-split-section-overview-0 .review-change-stat-del", "-1")

      assert has_element?(
               view,
               "#review-split-section-overview-0 .review-section-state-text",
               "Pending"
             )

      refute has_element?(view, "#packet-section-0 > .review-packet-section-summary-text")

      refute has_element?(
               view,
               "#packet-section-0 .review-packet-section-summary .review-packet-section-summary-text"
             )

      assert html =~ "Preserve packet JSON as the server contract."
      assert html =~ "Keep packet.md editable."
      assert html =~ "Run the smoke test"

      # The section header stays a header: grounding prose reads in the
      # content flow, not inside the overview.
      refute has_element?(
               view,
               "#review-split-section-overview-0",
               "Preserve packet JSON as the server contract."
             )

      assert has_element?(
               view,
               "#packet-section-0-row-0 .review-packet-md-heading + .review-packet-md-paragraph",
               "Preserve packet JSON as the server contract."
             )

      # No file inventory in the reading sequence.
      refute has_element?(view, "#packet-section-0 .review-guide-panel-files")

      # Decisions close the section reading order.
      assert has_element?(
               view,
               "#packet-section-0 .review-packet-row-list + #packet-section-0-decision"
             )

      assert has_element?(
               view,
               "#packet-section-0-decision .review-packet-section-signin",
               "Sign in to record a section decision"
             )

      assert has_element?(view, "#review-packet .review-hunk-card")
      refute has_element?(view, "#review-packet .review-hunk-summary")

      assert has_element?(
               view,
               ~s|#review-packet [phx-hook="DiffRenderer"][data-file-path="lib/packet.ex"][data-hunk-details^="lib/packet.ex"]|
             )

      assert has_element?(view, "#review-packet .review-packet-md-heading", "Main change")
      assert has_element?(view, "#review-packet", "Preserve packet JSON as the server contract.")
      assert has_element?(view, "#review-packet", "Keep packet.md editable.")
      assert has_element?(view, "#review-packet", "Run the smoke test.")

      assert has_element?(view, "#review-toolbar .review-toolbar-views > #code-view-switcher")
      assert has_element?(view, "#review-toolbar .review-toolbar-views > #diff-style-toggle")
      refute has_element?(view, "#revision-nav")
      refute has_element?(view, "#revision-mobile-nav")
      assert has_element?(view, "#packet-section-0-decision.is-readonly")

      view
      |> element("#diff-style-unified")
      |> render_click()

      assert has_element?(view, "#packet-section-0.is-open")
    end

    test "packet rows that slice the same hunk get independent UI ids", %{
      conn: conn,
      author: author
    } do
      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Packet slices",
          raw_diff: """
          diff --git a/lib/packet.ex b/lib/packet.ex
          --- a/lib/packet.ex
          +++ b/lib/packet.ex
          @@ -1,2 +1,2 @@
          -old_one
          +new_one
          -old_two
          +new_two
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => [
              %{
                "title" => "Split hunk",
                "rows" => [
                  %{
                    "kind" => "hunk",
                    "path" => "lib/packet.ex",
                    "hunk_index" => 1,
                    "line_start" => 1,
                    "line_end" => 2
                  },
                  %{
                    "kind" => "hunk",
                    "path" => "lib/packet.ex",
                    "hunk_index" => 1,
                    "line_start" => 3,
                    "line_end" => 4
                  }
                ]
              }
            ]
          }
        })

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      view |> element("#review-guide-tick-0") |> render_click()

      assert has_element?(
               view,
               ~s|#packet-section-0-row-0 [data-hunk-id="packet-section-0-row-0--hunk-lib-packet-ex-1"]|
             )

      assert has_element?(
               view,
               ~s|#packet-section-0-row-1 [data-hunk-id="packet-section-0-row-1--hunk-lib-packet-ex-1"]|
             )

      assert has_element?(
               view,
               ~s|#packet-section-0-row-0 [id="packet-section-0-row-0--hunk-lib-packet-ex-1-diff"]|
             )

      assert has_element?(
               view,
               ~s|#packet-section-0-row-1 [id="packet-section-0-row-1--hunk-lib-packet-ex-1-diff"]|
             )
    end

    test "consecutive packet hunks in the same file share one diff island", %{
      conn: conn,
      author: author
    } do
      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Packet consecutive hunks",
          raw_diff: """
          diff --git a/lib/packet.ex b/lib/packet.ex
          --- a/lib/packet.ex
          +++ b/lib/packet.ex
          @@ -1 +1 @@
          -old_one
          +new_one
          @@ -8 +8 @@
          -old_two
          +new_two
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => [
              %{
                "title" => "Consecutive hunks",
                "rows" => [
                  %{"kind" => "hunk", "path" => "lib/packet.ex", "hunk_index" => 1},
                  %{"kind" => "hunk", "path" => "lib/packet.ex", "hunk_index" => 2}
                ]
              }
            ]
          }
        })

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      view |> element("#review-guide-tick-0") |> render_click()

      assert has_element?(
               view,
               ~s|#packet-section-0-row-0[data-packet-row-ids="packet-section-0-row-0 packet-section-0-row-1"] [data-hunk-label="hunks 1-2"]|
             )

      assert has_element?(
               view,
               ~s|#packet-section-0-row-0 [id="packet-section-0-row-0--hunk-lib-packet-ex-1-through-2-diff"][phx-hook="DiffRenderer"]|
             )

      refute has_element?(view, "#packet-section-0-row-1 .review-hunk-card")

      refute has_element?(
               view,
               ~s|#packet-section-0-row-1 [phx-hook="DiffRenderer"]|
             )
    end

    test "packets land on overview and open section hunks only after selection", %{
      conn: conn,
      author: author
    } do
      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Small section",
          raw_diff: """
          diff --git a/lib/one.ex b/lib/one.ex
          --- a/lib/one.ex
          +++ b/lib/one.ex
          @@ -1 +1 @@
          -old_one
          +new_one
          diff --git a/lib/two.ex b/lib/two.ex
          --- a/lib/two.ex
          +++ b/lib/two.ex
          @@ -1 +1 @@
          -old_two
          +new_two
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => [
              %{
                "title" => "First section",
                "rows" => [
                  %{"kind" => "hunk", "path" => "lib/one.ex", "hunk_index" => 1},
                  %{"kind" => "hunk", "path" => "lib/two.ex", "hunk_index" => 1}
                ]
              },
              %{
                "title" => "Second section",
                "rows" => [
                  %{"kind" => "markdown", "body" => "No hunks here."}
                ]
              }
            ]
          }
        })

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}")

      assert has_element?(view, "#review-guide-overview-tick.is-active")
      assert has_element?(view, "#review-split-inline-overview", "Packet walkthrough")
      refute has_element?(view, "#packet-section-0")
      refute has_element?(view, "[phx-hook=DiffRenderer]")

      view |> element(".review-guide-begin") |> render_click()

      assert has_element?(view, "#packet-section-0.is-open")
      refute has_element?(view, "#packet-section-1")

      # Beginning the review opens the first section's hunks, like tick navigation.
      assert has_element?(
               view,
               ~s|#packet-section-0 [phx-hook="DiffRenderer"][data-file-path="lib/one.ex"][data-hunk-expanded="true"]|
             )

      # The decision footer leads into the next section.
      assert has_element?(
               view,
               "#packet-section-0-nav .review-section-next-button",
               "Next: 02 Second section"
             )

      view
      |> element("#packet-section-0-nav .review-section-next-button")
      |> render_click()

      assert has_element?(view, "#packet-section-1.is-open")
      refute has_element?(view, "#packet-section-0")

      assert has_element?(
               view,
               "#packet-section-1-nav .review-section-next-button",
               "Back to overview"
             )

      view |> element("#diff-style-unified") |> render_click()

      assert has_element?(view, "#review-split-section-overview-1", "Second section")

      assert has_element?(
               view,
               "#packet-section-1-body .review-packet-markdown",
               "No hunks here."
             )

      refute has_element?(view, "#review-guide-panel")
      refute has_element?(view, "#packet-section-1 [phx-hook=DiffRenderer]")

      view |> element("#diff-style-split") |> render_click()

      view
      |> element("#review-guide-tick-0")
      |> render_click()

      assert has_element?(
               view,
               ~s|#packet-section-0 [phx-hook="DiffRenderer"][data-file-path="lib/one.ex"][data-hunk-expanded="true"]|
             )

      assert has_element?(
               view,
               ~s|#packet-section-0 [phx-hook="DiffRenderer"][data-file-path="lib/two.ex"][data-hunk-expanded="true"]|
             )
    end

    test "renders linear revision navigation from patchsets", %{
      conn: conn,
      author: author
    } do
      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Revision nav",
          raw_diff: """
          diff --git a/lib/one.ex b/lib/one.ex
          --- a/lib/one.ex
          +++ b/lib/one.ex
          @@ -1 +1 @@
          -old
          +new
          """,
          packet: %{
            "format_version" => 1,
            "title" => "First packet",
            "sections" => []
          }
        })

      {:ok, _ps2} =
        ReviewsCtx.append_patchset(packet_review, %{
          raw_diff: """
          diff --git a/lib/two.ex b/lib/two.ex
          --- a/lib/two.ex
          +++ b/lib/two.ex
          @@ -1 +1 @@
          -old
          +new
          """
        })

      {:ok, _ps3} =
        ReviewsCtx.append_patchset(packet_review, %{
          raw_diff: """
          diff --git a/lib/three.ex b/lib/three.ex
          --- a/lib/three.ex
          +++ b/lib/three.ex
          @@ -1 +1 @@
          -old
          +new
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Second packet",
            "sections" => []
          }
        })

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}")

      assert has_element?(view, "#revision-nav", "Revision 3 of 3")
      assert has_element?(view, "#revision-nav", "v1")
      assert has_element?(view, "#revision-nav", "v2")
      assert has_element?(view, "#revision-nav", "v3")
      assert has_element?(view, ".review-header-meta", "+1 -1")
      assert has_element?(view, ~s|#revision-nav #patchset-3.is-active|, "v3")
      assert has_element?(view, ~s|#revision-nav #patchset-1.has-packet|)
      assert has_element?(view, ~s|#revision-nav #patchset-3.has-packet|)

      view |> element("#patchset-1") |> render_click()
      assert has_element?(view, "#patchset-1.is-active")
      assert has_element?(view, "#previous-revision[disabled]")

      view |> element("#next-revision") |> render_click()
      assert has_element?(view, "#patchset-2.is-active")

      assert has_element?(view, ~s|#mobile-revision option[value="2"][selected]|)

      view
      |> form("#revision-mobile-nav", %{"number" => "1"})
      |> render_change()

      assert has_element?(view, "#patchset-1.is-active")
      assert has_element?(view, ~s|#mobile-revision option[value="1"][selected]|)
    end

    test "shows an empty reviewers stack before anyone reviews", %{conn: conn, review: review} do
      {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}")

      assert has_element?(view, "#decider-stack.is-empty", "No reviews yet")
    end

    test "renders published reviewers, including agents, for anonymous viewers", %{
      conn: conn,
      review: review
    } do
      {:ok, reviewer} =
        Accounts.upsert_from_github(%{
          github_id: 5678,
          username: "zara",
          email: "zara@example.com",
          avatar_url: nil
        })

      {:ok, agent} =
        Accounts.create_agent_identity(reviewer, %{display_name: "Codex", handle: "codex"})

      {:ok, %{comment: zara_comment}} = Threads.publish_comment(review, reviewer, foo_comment())
      {:ok, %{comment: agent_comment}} = Threads.publish_comment(review, agent, foo_comment())

      {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}")

      zara = "#decider-stack-#{zara_comment.author_id}"
      codex = "#decider-stack-#{agent_comment.author_id}"

      assert has_element?(view, ~s|#{zara}.is-commented[title="@zara: commented · 1 comment"]|)
      assert has_element?(view, ~s|#{zara} .rev-decider-badge .hero-chat-bubble-left-ellipsis|)

      assert has_element?(
               view,
               ~s|#{codex}[data-kind="agent"][title="@codex (agent): commented · 1 comment"]|
             )

      assert has_element?(view, ~s|#{codex} .rev-decider-avatar .hero-cpu-chip|)
      refute has_element?(view, "#decider-stack-more")
    end

    test "collapses reviewers past the fifth into a +N chip", %{conn: conn, review: review} do
      for n <- 1..7 do
        {:ok, user} =
          Accounts.upsert_from_github(%{
            github_id: 9000 + n,
            username: "reviewer-#{n}",
            email: "reviewer-#{n}@example.com",
            avatar_url: "https://example.com/#{n}.png"
          })

        {:ok, _} = Threads.publish_comment(review, user, foo_comment())
      end

      {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}")

      assert has_element?(
               view,
               ~s|#decider-stack .rev-decider img[src="https://example.com/5.png"]|
             )

      refute has_element?(
               view,
               ~s|#decider-stack .rev-decider img[src="https://example.com/6.png"]|
             )

      assert has_element?(
               view,
               ~s|#decider-stack-more[title="2 more reviewers: @reviewer-6, @reviewer-7"]|,
               "+2"
             )
    end

    test "updates the reviewers stack live when an agent decides through the API", %{
      conn: conn
    } do
      {:ok, owner} =
        Accounts.upsert_from_github(%{
          github_id: 8765,
          username: "owner",
          email: "owner@example.com",
          avatar_url: nil
        })

      {:ok, %{review: packet_review, patchset: patchset}} =
        ReviewsCtx.create_review_with_initial_patchset(owner, %{
          title: "Packet for an agent",
          raw_diff: """
          diff --git a/lib/packet.ex b/lib/packet.ex
          --- a/lib/packet.ex
          +++ b/lib/packet.ex
          @@ -1 +1 @@
          -old
          +new
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => [
              %{
                "title" => "Main change",
                "rows" => [
                  %{
                    "kind" => "hunk",
                    "path" => "lib/packet.ex",
                    "hunk_index" => 1,
                    "line_start" => 1,
                    "line_end" => 2
                  }
                ]
              }
            ]
          }
        })

      {:ok, agent} =
        Accounts.create_agent_identity(owner, %{display_name: "Codex", handle: "codex"})

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      assert has_element?(view, "#decider-stack.is-empty")

      section = Reviews.ReviewPacket.section_at(patchset.packet, 0)

      {:ok, _} =
        Reviews.PacketSectionDecisions.put_section_status(
          packet_review,
          patchset,
          agent,
          section,
          [],
          [patchset],
          "denied"
        )

      assert has_element?(
               view,
               ~s|#decider-stack-#{agent.id}.is-denied[data-kind="agent"]|
             )

      decisions = Reviews.PacketSectionDecisions.list_for_review(packet_review, agent)

      {:ok, nil} =
        Reviews.PacketSectionDecisions.put_section_status(
          packet_review,
          patchset,
          agent,
          section,
          decisions,
          [patchset],
          "denied"
        )

      assert has_element?(view, "#decider-stack.is-empty")
    end

    test "does not render the old publish review button", %{conn: conn, review: review} do
      {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}")
      refute has_element?(view, "#publish-review-button")
    end

    test "renders small diffs by default on the changes route", %{conn: conn, author: author} do
      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Packet change",
          raw_diff: """
          diff --git a/lib/packet.ex b/lib/packet.ex
          --- a/lib/packet.ex
          +++ b/lib/packet.ex
          @@ -1 +1 @@
          -old
          +new
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => [
              %{
                "title" => "Main change",
                "rows" => [
                  %{"kind" => "hunk", "path" => "lib/packet.ex", "hunk_index" => 1}
                ]
              }
            ]
          }
        })

      {:ok, packet_view, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      assert has_element?(packet_view, "#review-packet")

      assert has_element?(
               packet_view,
               "#code-view-switcher .review-code-view-tab.is-active",
               "Guide"
             )

      assert has_element?(packet_view, "#code-view-switcher .review-code-view-tab", "Diff")
      refute has_element?(packet_view, "#diff-files")

      {:ok, changes_view, _html} = live(conn, ~p"/r/#{packet_review.slug}/changes")
      assert has_element?(changes_view, "#diff-files")

      assert has_element?(
               changes_view,
               "#code-view-switcher .review-code-view-tab.is-active",
               "Diff"
             )

      assert has_element?(changes_view, "#code-view-switcher .review-code-view-tab", "Guide")
      refute has_element?(changes_view, "#file-tree")
      refute has_element?(changes_view, "#diff-files .rev-file-card")
      refute has_element?(changes_view, "#diff-files .rev-file-placeholder")

      assert has_element?(changes_view, "#diff-files .review-hunk-card")
      refute has_element?(changes_view, "#diff-files .review-hunk-summary")

      assert has_element?(
               changes_view,
               ~s|[phx-hook="DiffRenderer"][data-file-path="lib/packet.ex"][data-hunk-expanded="true"]|
             )

      changes_view
      |> element("#diff-style-unified")
      |> render_click()

      refute has_element?(changes_view, "#file-tree")
      refute has_element?(changes_view, "#review-guide-sidebar")
      refute has_element?(changes_view, "#review-guide-rail")
      refute has_element?(changes_view, "#changes-file-tree")
      refute has_element?(changes_view, "#review-guide-shell")

      refute has_element?(changes_view, "#diff-files .review-hunk-summary")

      changes_view
      |> element("#diff-style-split")
      |> render_click()

      refute has_element?(changes_view, "#file-tree")
      refute has_element?(changes_view, "#review-guide-shell")
    end

    test "guide rail preserves section layout across diff styles and when hidden", %{
      conn: conn,
      author: author
    } do
      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Packet active section",
          raw_diff: """
          diff --git a/lib/first.ex b/lib/first.ex
          --- a/lib/first.ex
          +++ b/lib/first.ex
          @@ -1 +1 @@
          -old_first
          +new_first
          diff --git a/lib/second.ex b/lib/second.ex
          --- a/lib/second.ex
          +++ b/lib/second.ex
          @@ -1 +1 @@
          -old_second
          +new_second
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Active outline",
            "summary" => "Packet-level overview for the guided review.",
            "sections" => [
              %{
                "title" => "Primary reasoning",
                "rows" => [
                  %{
                    "kind" => "markdown",
                    "body" =>
                      "This first paragraph explains why the entrypoint change matters before the reviewer looks at the code."
                  },
                  %{"kind" => "hunk", "path" => "lib/first.ex", "hunk_index" => 1},
                  %{
                    "kind" => "markdown",
                    "body" =>
                      "This interspersed commentary stays with the code hunk after the lead paragraph."
                  }
                ]
              },
              %{
                "title" => "Secondary consequence",
                "rows" => [
                  %{
                    "kind" => "markdown",
                    "body" =>
                      "This second paragraph should stay out of the way until the reviewer makes this section active."
                  },
                  %{"kind" => "hunk", "path" => "lib/second.ex", "hunk_index" => 1}
                ]
              }
            ]
          }
        })

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}")

      assert has_element?(view, ".review-packet-shell.has-outline")
      assert has_element?(view, "#review-guide-shell")
      assert has_element?(view, "#review-guide-flyout")
      assert has_element?(view, "#review-guide-tick-0 .review-edge-tick-number", "01")
      assert has_element?(view, ".review-guide-flyout-item .review-guide-flyout-num", "01")
      assert has_element?(view, "#review-split-inline-overview", "Active outline")
      assert has_element?(view, "#review-guide-overview-tick.is-active")

      view |> element("#review-guide-tick-0") |> render_click()

      refute has_element?(view, "#review-split-inline-overview")
      assert has_element?(view, "#review-split-section-overview-0", "Primary reasoning")

      assert has_element?(
               view,
               "#review-split-section-overview-0 .review-section-state-text",
               "Pending"
             )

      # Grounding prose reads in the section flow, not in the header.
      refute has_element?(view, "#review-split-section-overview-0", "entrypoint change matters")
      assert has_element?(view, "#packet-section-0", "entrypoint change matters")
      assert has_element?(view, "#packet-section-0.is-open")
      refute has_element?(view, "#packet-section-1")

      view
      |> element("#review-guide-overview-tick")
      |> render_click()

      assert has_element?(view, "#review-guide-overview-tick.is-active")
      assert has_element?(view, "#review-split-inline-overview", "Active outline")
      assert has_element?(view, "#review-split-inline-overview", "Packet-level overview")
      refute has_element?(view, "#packet-section-0")

      send(view.pid, {:patchset_pushed, 1})
      _ = render(view)

      assert has_element?(view, "#review-guide-overview-tick.is-active")
      assert has_element?(view, "#review-split-inline-overview")
      refute has_element?(view, "#packet-section-0")

      view
      |> element("#review-guide-tick-0")
      |> render_click()

      view
      |> element("#diff-style-unified")
      |> render_click()

      assert has_element?(view, ".review-packet-shell.has-outline")
      assert has_element?(view, ~s|#review-guide-shell[phx-hook$=".GuideFlyout"]|)
      assert has_element?(view, "#review-guide-tick-0.is-active")
      refute has_element?(view, "#review-split-inline-overview")

      assert has_element?(view, "#packet-section-0.is-open")
      assert has_element?(view, "#review-split-section-overview-0", "Primary reasoning")

      assert has_element?(
               view,
               "#packet-section-0-body",
               "entrypoint change matters"
             )

      refute has_element?(view, "#review-guide-panel")
      assert has_element?(view, "#packet-section-0", "interspersed commentary")
      assert has_element?(view, "#review-guide-flyout .review-guide-flyout-file", "first.ex")
      refute has_element?(view, "#packet-section-0", "stay out of the way")
      refute has_element?(view, "#review-guide-flyout .review-guide-flyout-file", "second.ex")

      view
      |> element("#review-guide-tick-1")
      |> render_click()

      assert has_element?(view, "#review-guide-tick-1.is-active")

      assert has_element?(view, "#packet-section-1.is-open")
      assert has_element?(view, "#review-split-section-overview-1", "Secondary consequence")

      assert has_element?(
               view,
               "#packet-section-1-body",
               "stay out of the way"
             )

      refute has_element?(view, "#packet-section-0")
      refute has_element?(view, "#packet-section-1", "entrypoint change matters")

      view
      |> element("#review-guide-overview-tick")
      |> render_click()

      assert has_element?(view, "#review-guide-overview-tick.is-active")

      view |> element("#review-guide-tick-1") |> render_click()
      view |> element("#review-guide-shell .review-packet-nav-hide") |> render_click()

      refute has_element?(view, "#review-guide-shell")
      assert has_element?(view, "#review-split-section-overview-0", "Primary reasoning")
      assert has_element?(view, "#review-split-section-overview-1", "Secondary consequence")
      assert has_element?(view, "#packet-section-0-body", "entrypoint change matters")
      assert has_element?(view, "#packet-section-1-body", "stay out of the way")
      refute has_element?(view, "#packet-section-0 .review-packet-section-summary")
      refute has_element?(view, "#packet-section-1 .review-packet-section-summary")

      view |> element(".review-outline-toggle") |> render_click()

      assert has_element?(view, "#review-guide-tick-1.is-active")
      assert has_element?(view, "#packet-section-1-body", "stay out of the way")
      refute has_element?(view, "#packet-section-0")
    end

    test "changes route renders one collapsible diff island per file", %{
      conn: conn,
      author: author
    } do
      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Packet file island",
          raw_diff: """
          diff --git a/lib/packet.ex b/lib/packet.ex
          --- a/lib/packet.ex
          +++ b/lib/packet.ex
          @@ -1 +1 @@
          -old_one
          +new_one
          @@ -8 +8 @@
          -old_two
          +new_two
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => []
          }
        })

      {:ok, changes_view, _html} = live(conn, ~p"/r/#{packet_review.slug}/changes")

      refute has_element?(changes_view, "#file-tree")
      assert has_element?(changes_view, "#diff-files .review-hunk-card.is-file-diff")

      assert has_element?(
               changes_view,
               ~s|#diff-files .review-hunk-card.is-file-diff [data-hunk-view-state="2 hunks"]|
             )

      refute has_element?(changes_view, "#diff-files .review-hunk-card:not(.is-file-diff)")

      refute has_element?(
               changes_view,
               ~s|#diff-files .review-hunk-card.is-file-diff [data-hunk-label="hunks 1-2"]|
             )

      assert has_element?(
               changes_view,
               ~s|#diff-files [id^="file-diff-"][id$="-diff"][phx-hook="DiffRenderer"][data-file-path="lib/packet.ex"]|
             )
    end

    test "opens large diffs on the changes route", %{conn: conn, author: author} do
      large_changes =
        1..500
        |> Enum.map(fn index -> "-old_#{index}\n+new_#{index}" end)
        |> Enum.join("\n")

      {:ok, %{review: large_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Large change",
          raw_diff: """
          diff --git a/lib/large.ex b/lib/large.ex
          --- a/lib/large.ex
          +++ b/lib/large.ex
          @@ -1,500 +1,500 @@
          #{large_changes}
          """
        })

      {:ok, changes_view, _html} = live(conn, ~p"/r/#{large_review.slug}/changes")

      assert has_element?(changes_view, "#diff-files .review-hunk-card.is-file-diff")

      assert has_element?(
               changes_view,
               ~s|#diff-files [phx-hook="DiffRenderer"][data-file-path="lib/large.ex"][data-hunk-expanded="true"]|
             )
    end

    test "selecting a section opens every diff regardless of line or file count", %{
      conn: conn,
      author: author
    } do
      for {file_count, line_count} <- [{2, 500}, {25, 1}] do
        raw_diff =
          Enum.map_join(1..file_count, "\n", fn file ->
            changes = Enum.map_join(1..line_count, "\n", &"-old_#{&1}\n+new_#{&1}")

            """
            diff --git a/lib/file_#{file}.ex b/lib/file_#{file}.ex
            --- a/lib/file_#{file}.ex
            +++ b/lib/file_#{file}.ex
            @@ -1,#{line_count} +1,#{line_count} @@
            #{changes}
            """
          end)

        {:ok, %{review: review}} =
          ReviewsCtx.create_review_with_initial_patchset(author, %{
            title: "Unrestricted section expansion",
            raw_diff: raw_diff,
            packet: %{
              "format_version" => 1,
              "title" => "Large section",
              "sections" => [
                %{
                  "title" => "All changes",
                  "rows" =>
                    Enum.map(1..file_count, fn file ->
                      %{"kind" => "hunk", "path" => "lib/file_#{file}.ex", "hunk_index" => 1}
                    end)
                }
              ]
            }
          })

        {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}")
        assert has_element?(view, "#review-guide-overview-tick.is-active")
        refute has_element?(view, "[phx-hook=DiffRenderer]")

        view |> element("#review-guide-tick-0") |> render_click()

        for file <- 1..file_count do
          assert has_element?(
                   view,
                   ~s|#packet-section-0 [phx-hook="DiffRenderer"][data-file-path="lib/file_#{file}.ex"][data-hunk-expanded="true"]|
                 )
        end
      end
    end

    test "opens each file diff under the line limit even when the patchset total is large", %{
      conn: conn,
      author: author
    } do
      first_changes =
        1..300
        |> Enum.map(fn index -> "-old_a_#{index}\n+new_a_#{index}" end)
        |> Enum.join("\n")

      second_changes =
        1..300
        |> Enum.map(fn index -> "-old_b_#{index}\n+new_b_#{index}" end)
        |> Enum.join("\n")

      {:ok, %{review: mixed_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Many small files",
          raw_diff: """
          diff --git a/lib/first.ex b/lib/first.ex
          --- a/lib/first.ex
          +++ b/lib/first.ex
          @@ -1,300 +1,300 @@
          #{first_changes}
          diff --git a/lib/second.ex b/lib/second.ex
          --- a/lib/second.ex
          +++ b/lib/second.ex
          @@ -1,300 +1,300 @@
          #{second_changes}
          """
        })

      {:ok, changes_view, _html} = live(conn, ~p"/r/#{mixed_review.slug}/changes")

      refute has_element?(changes_view, "#code-view-switcher")

      assert has_element?(
               changes_view,
               ~s|#diff-files [phx-hook="DiffRenderer"][data-file-path="lib/first.ex"]|
             )

      assert has_element?(
               changes_view,
               ~s|#diff-files [phx-hook="DiffRenderer"][data-file-path="lib/second.ex"]|
             )

      changes_view
      |> element("#diff-style-unified")
      |> render_click()

      refute has_element?(changes_view, "#file-tree")
      refute has_element?(changes_view, ~s|#changes-file-tree[phx-hook="ChangesFileTree"]|)
      refute has_element?(changes_view, "#review-guide-sidebar")
      assert has_element?(changes_view, "#diff-files")
    end
  end

  describe "signed-in reviewer" do
    setup :seed!

    setup %{author: author, conn: conn} do
      conn = Plug.Test.init_test_session(conn, %{current_user_id: author.id})
      %{conn: conn}
    end

    test "packet outline visibility is saved to the signed-in user's preferences", %{
      conn: conn,
      author: author
    } do
      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Packet outline preference",
          raw_diff: """
          diff --git a/lib/packet.ex b/lib/packet.ex
          --- a/lib/packet.ex
          +++ b/lib/packet.ex
          @@ -1 +1 @@
          -old
          +new
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => [
              %{
                "title" => "Main change",
                "rows" => [
                  %{
                    "kind" => "hunk",
                    "path" => "lib/packet.ex",
                    "hunk_index" => 1
                  }
                ]
              }
            ]
          }
        })

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}")

      assert has_element?(view, "#review-guide-shell")

      view
      |> element("#diff-style-unified")
      |> render_click()

      assert has_element?(view, "#review-guide-shell")
      refute has_element?(view, "#review-outline-toggle")

      view
      |> element("#review-guide-shell .review-packet-nav-hide")
      |> render_click()

      refute has_element?(view, "#review-guide-shell")
      assert has_element?(view, ~s|#review-outline-toggle[aria-label="Show section navigation"]|)

      author = Accounts.get_user!(author.id)
      assert Accounts.get_user_preference(author, :packet_outline_visible, true) == false

      {:ok, next_view, _html} = live(conn, ~p"/r/#{packet_review.slug}")

      refute has_element?(next_view, "#review-guide-shell")
      assert has_element?(next_view, "#review-split-inline-overview", "Packet walkthrough")

      next_view
      |> element("#diff-style-unified")
      |> render_click()

      refute has_element?(next_view, "#review-guide-shell")

      assert has_element?(
               next_view,
               ~s|#review-outline-toggle[aria-label="Show section navigation"]|
             )
    end

    test "comments are visible immediately once created", %{
      conn: conn,
      author: author,
      review: review
    } do
      {:ok, _} =
        Threads.publish_comment(review, author, %{
          "file_path" => "lib/foo.ex",
          "side" => "new",
          "body" => "what about :renamed?",
          "thread_anchor" => %{
            "granularity" => "line",
            "line_text" => "  def bar, do: :new",
            "context_before" => [],
            "context_after" => [],
            "line_number_hint" => 2
          }
        })

      {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}")

      refute has_element?(view, "#publish-review-button")

      [thread] = Threads.list_published_threads(review.id)
      [comment] = thread.comments
      assert comment.body == "what about :renamed?"
    end

    test "create_comment event persists immediately via Threads.publish_comment", %{
      conn: conn,
      review: review
    } do
      {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}")

      render_hook(view, "create_comment", %{
        "file_path" => "lib/foo.ex",
        "side" => "new",
        "body" => "from-hook",
        "thread_anchor" => %{
          "granularity" => "line",
          "line_text" => "  def bar, do: :new",
          "context_before" => [],
          "context_after" => [],
          "line_number_hint" => 2
        }
      })

      assert [thread] = Threads.list_published_threads(review.id)
      assert [comment] = thread.comments
      assert comment.body == "from-hook"
    end

    test "hunk viewed state is shared between packet and changes views", %{
      conn: conn,
      author: author
    } do
      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Packet hunk viewed",
          raw_diff: """
          diff --git a/lib/packet.ex b/lib/packet.ex
          --- a/lib/packet.ex
          +++ b/lib/packet.ex
          @@ -1 +1 @@
          -old
          +new
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => [
              %{
                "title" => "Main change",
                "rows" => [
                  %{"kind" => "hunk", "path" => "lib/packet.ex", "hunk_index" => 1}
                ]
              }
            ]
          }
        })

      {:ok, packet_view, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      packet_view |> element("#review-guide-tick-0") |> render_click()

      params =
        hunk_view_params(packet_review, "lib/packet.ex", 1, %{
          "hunk_id" => "packet-section-0-row-0--hunk-lib-packet-ex-1",
          "section_index" => 0,
          "section_title" => "Main change"
        })

      render_click(packet_view, "mark_hunk_viewed", params)

      assert has_element?(
               packet_view,
               ~s|#packet-section-0 [phx-hook="DiffRenderer"][data-hunk-viewed="true"]|
             )

      {:ok, changes_view, _html} = live(conn, ~p"/r/#{packet_review.slug}/changes")

      assert has_element?(changes_view, ~s|#diff-files [data-hunk-viewed="true"]|)

      render_click(
        changes_view,
        "mark_hunk_unviewed",
        hunk_view_params(packet_review, "lib/packet.ex", 1, %{
          "hunk_id" => changes_hunk_id(packet_review, "lib/packet.ex")
        })
      )

      refute has_element?(changes_view, ~s|#diff-files [data-hunk-viewed="true"]|)

      {:ok, packet_view_after_clear, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      packet_view_after_clear |> element("#review-guide-tick-0") |> render_click()

      refute has_element?(
               packet_view_after_clear,
               ~s|#packet-section-0 [data-hunk-viewed="true"]|
             )
    end

    test "deleted file hunks can be marked viewed", %{conn: conn, author: author} do
      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Deleted packet hunk viewed",
          raw_diff: """
          diff --git a/lib/deleted.ex b/lib/deleted.ex
          deleted file mode 100644
          index 3b18e51..0000000
          --- a/lib/deleted.ex
          +++ /dev/null
          @@ -1,2 +0,0 @@
          -old_one
          -old_two
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => [
              %{
                "title" => "Deleted file",
                "rows" => [
                  %{"kind" => "hunk", "path" => "lib/deleted.ex", "hunk_index" => 1}
                ]
              }
            ]
          }
        })

      {:ok, packet_view, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      packet_view |> element("#review-guide-tick-0") |> render_click()

      render_click(
        packet_view,
        "mark_hunk_viewed",
        hunk_view_params(packet_review, "lib/deleted.ex", 1, %{
          "hunk_id" => "packet-section-0-row-0--hunk-lib-deleted-ex-1",
          "section_index" => 0,
          "section_title" => "Deleted file"
        })
      )

      assert has_element?(
               packet_view,
               ~s|#packet-section-0 [phx-hook="DiffRenderer"][data-hunk-viewed="true"]|
             )

      refute render(packet_view) =~ "Could not update hunk."

      [viewed] = PacketHunkViews.list_for_review(packet_review, author)
      assert viewed.file_path == "lib/deleted.ex"
      assert viewed.hunk_index == 1
      assert viewed.line_start == 1
      assert viewed.line_end == 2
    end

    test "grouped packet hunks can be marked viewed and show partial state", %{
      conn: conn,
      author: author
    } do
      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Grouped viewed",
          raw_diff: """
          diff --git a/lib/grouped.ex b/lib/grouped.ex
          --- a/lib/grouped.ex
          +++ b/lib/grouped.ex
          @@ -1 +1 @@
          -old_one
          +new_one
          @@ -8 +8 @@
          -old_two
          +new_two
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => [
              %{
                "title" => "Grouped hunks",
                "rows" => [
                  %{"kind" => "hunk", "path" => "lib/grouped.ex", "hunk_index" => 1},
                  %{"kind" => "hunk", "path" => "lib/grouped.ex", "hunk_index" => 2}
                ]
              }
            ]
          }
        })

      {:ok, packet_view, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      packet_view |> element("#review-guide-tick-0") |> render_click()

      hunk_id = "packet-section-0-row-0--hunk-lib-grouped-ex-1-through-2"

      render_click(
        packet_view,
        "mark_hunk_viewed",
        grouped_hunk_view_params(packet_review, "lib/grouped.ex", hunk_id)
      )

      assert has_element?(
               packet_view,
               ~s|#packet-section-0 [phx-hook="DiffRenderer"][data-hunk-viewed="true"]|
             )

      {:ok, changes_view, _html} = live(conn, ~p"/r/#{packet_review.slug}/changes")
      assert has_element?(changes_view, ~s|#diff-files [data-hunk-viewed="true"]|)

      [cleared_view | _] = PacketHunkViews.list_for_review(packet_review, author)
      attrs = Map.take(cleared_view, [:file_path, :row_ref, :hunk_fingerprint])
      {:ok, _} = PacketHunkViews.clear_viewed(packet_review, author, attrs)

      {:ok, packet_view_after_clear, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      packet_view_after_clear |> element("#review-guide-tick-0") |> render_click()

      assert has_element?(
               packet_view_after_clear,
               ~s|#packet-section-0 [phx-hook="DiffRenderer"][data-hunk-viewed="false"][data-hunk-partially-viewed="true"]|
             )
    end

    test "a section decision shows up in the reviewers stack", %{conn: conn, author: author} do
      {:ok, owner} =
        Accounts.upsert_from_github(%{
          github_id: 4321,
          username: "owner",
          email: "owner@example.com",
          avatar_url: nil
        })

      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(owner, %{
          title: "Someone else's packet",
          raw_diff: """
          diff --git a/lib/packet.ex b/lib/packet.ex
          --- a/lib/packet.ex
          +++ b/lib/packet.ex
          @@ -1 +1 @@
          -old
          +new
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => [
              %{
                "title" => "Main change",
                "rows" => [
                  %{
                    "kind" => "hunk",
                    "path" => "lib/packet.ex",
                    "hunk_index" => 1,
                    "line_start" => 1,
                    "line_end" => 2
                  }
                ]
              }
            ]
          }
        })

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      assert has_element?(view, "#decider-stack.is-empty")

      view |> element("#review-guide-tick-0") |> render_click()
      view |> element("#packet-section-0 button", "Approve") |> render_click()

      {:ok, identity} = Accounts.ensure_human_identity(author)

      assert has_element?(
               view,
               ~s|#decider-stack-#{identity.id}.is-approved[title="@carey: approved 1 of 1 section"]|
             )

      assert has_element?(view, "#decider-stack-#{identity.id} .rev-decider-badge .hero-check")

      view
      |> element(~s|#packet-section-0 button[aria-label="Request changes"]|)
      |> render_click()

      assert has_element?(view, "#decider-stack-#{identity.id}.is-denied")
    end

    test "section decisions persist and later changed sections link to the previous decision", %{
      conn: conn,
      author: author
    } do
      diff_v1 = """
      diff --git a/lib/packet.ex b/lib/packet.ex
      --- a/lib/packet.ex
      +++ b/lib/packet.ex
      @@ -1 +1 @@
      -old
      +new
      """

      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Packet decision",
          raw_diff: diff_v1,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => [
              %{
                "title" => "Main change",
                "rows" => [
                  %{
                    "kind" => "hunk",
                    "path" => "lib/packet.ex",
                    "hunk_index" => 1,
                    "line_start" => 1,
                    "line_end" => 2
                  }
                ]
              }
            ]
          }
        })

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}?patchset=1")
      assert has_element?(view, "#review-guide-overview-tick.is-active")
      view |> element("#review-guide-tick-0") |> render_click()
      assert has_element?(view, "#packet-section-0.is-open")

      view |> element("#packet-section-0-decision button", "Approve") |> render_click()
      assert has_element?(view, "#packet-section-0.is-open")

      assert has_element?(view, "#packet-section-0 .review-section-action.is-active", "Approve")

      assert has_element?(
               view,
               "#review-split-section-overview-0 .review-section-state-text",
               "Approved"
             )

      view |> element("#packet-section-0-decision button", "Approve") |> render_click()
      assert has_element?(view, "#packet-section-0.is-open")
      refute has_element?(view, "#packet-section-0 .review-section-action.is-active")

      assert has_element?(
               view,
               "#review-split-section-overview-0 .review-section-state-text",
               "Pending"
             )

      view |> element("#packet-section-0-decision button", "Approve") |> render_click()
      assert has_element?(view, "#packet-section-0 .review-section-action.is-active", "Approve")

      {:ok, _ps2} =
        ReviewsCtx.append_patchset(packet_review, %{
          raw_diff: """
          diff --git a/lib/packet.ex b/lib/packet.ex
          --- a/lib/packet.ex
          +++ b/lib/packet.ex
          @@ -1,2 +1,3 @@
          -old
          +newer
          +again
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => [
              %{
                "title" => "Main change",
                "rows" => [
                  %{
                    "kind" => "hunk",
                    "path" => "lib/packet.ex",
                    "hunk_index" => 1,
                    "line_start" => 1,
                    "line_end" => 3
                  }
                ]
              }
            ]
          }
        })

      {:ok, latest_view, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      assert has_element?(latest_view, "#review-guide-overview-tick.is-active")
      latest_view |> element("#review-guide-tick-0") |> render_click()

      render_click(latest_view, "select_patchset", %{"number" => "1"})
      assert has_element?(latest_view, "#review-guide-overview-tick.is-active")
      assert has_element?(latest_view, "#review-split-inline-overview")
      refute has_element?(latest_view, "#packet-section-0")

      render_click(latest_view, "select_patchset", %{"number" => "2"})
      assert has_element?(latest_view, "#review-guide-overview-tick.is-active")
      latest_view |> element("#review-guide-tick-0") |> render_click()
      refute has_element?(latest_view, "#packet-section-0 .review-section-action.is-active")

      assert has_element?(
               latest_view,
               "#review-split-section-overview-0 .review-section-state-text",
               "Pending for this revision"
             )

      assert has_element?(
               latest_view,
               "#review-split-section-overview-0 .review-section-state-history",
               "Previously approved in v1; outdated for v2."
             )

      assert has_element?(
               latest_view,
               "#packet-section-0-decision .review-section-decision-history",
               "Previously approved in v1"
             )

      assert has_element?(latest_view, "#packet-section-0 .review-packet-section-actions")
      assert has_element?(latest_view, "#packet-section-0.is-open")

      latest_view |> element("#packet-section-0-decision button", "Skip") |> render_click()

      assert has_element?(
               latest_view,
               "#review-split-section-overview-0 .review-section-state-history",
               "Previously approved in v1"
             )

      assert has_element?(
               latest_view,
               "#packet-section-0 .review-section-action.is-active",
               "Skip"
             )

      {:ok, _ps3} =
        ReviewsCtx.append_patchset(packet_review, %{
          raw_diff: """
          diff --git a/lib/packet.ex b/lib/packet.ex
          --- a/lib/packet.ex
          +++ b/lib/packet.ex
          @@ -1,2 +1,3 @@
          -old
          +newer
          +again
          """,
          packet: %{
            "format_version" => 1,
            "title" => "Packet walkthrough",
            "sections" => [
              %{
                "title" => "Main change",
                "rows" => [
                  %{
                    "kind" => "hunk",
                    "path" => "lib/packet.ex",
                    "hunk_index" => 1,
                    "line_start" => 1,
                    "line_end" => 3
                  }
                ]
              }
            ]
          }
        })

      {:ok, carried_view, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      carried_view |> element("#review-guide-tick-0") |> render_click()

      assert has_element?(
               carried_view,
               "#packet-section-0 .review-section-action.is-active",
               "Skip"
             )

      assert has_element?(
               carried_view,
               "#review-split-section-overview-0 .review-section-state-text",
               "Skipped (carried forward)"
             )

      refute has_element?(
               carried_view,
               "#review-split-section-overview-0 .review-section-state-history"
             )

      carried_view |> element("#packet-section-0-decision button", "Skip") |> render_click()
      refute has_element?(carried_view, "#packet-section-0 .review-section-action.is-active")
    end
  end

  defp foo_comment do
    %{
      "file_path" => "lib/foo.ex",
      "side" => "new",
      "body" => "ship it",
      "thread_anchor" => %{
        "granularity" => "line",
        "line_text" => "  def bar, do: :new",
        "context_before" => [],
        "context_after" => [],
        "line_number_hint" => 2
      }
    }
  end
end
