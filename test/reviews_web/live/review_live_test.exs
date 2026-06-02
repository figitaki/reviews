defmodule ReviewsWeb.ReviewLiveTest do
  use ReviewsWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Reviews.Accounts
  alias Reviews.PacketHunkViews
  alias Reviews.Reviews, as: ReviewsCtx
  alias Reviews.Threads

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

    test "renders the review screen with file tree and defers diff hooks", %{
      conn: conn,
      review: review
    } do
      {:ok, view, html} = live(conn, ~p"/r/#{review.slug}")

      assert html =~ "Great change"
      assert html =~ "lib/foo.ex"
      refute html =~ "phx-hook=\"DiffRenderer\""

      assert has_element?(view, "#diff-files .review-hunk-card")
      refute has_element?(view, ~s|[phx-hook="DiffRenderer"][data-file-path="lib/foo.ex"]|)

      view
      |> element(~s|#diff-files .review-hunk-toggle[title^="lib/foo.ex"]|)
      |> render_click()

      assert has_element?(view, ~s|[phx-hook="DiffRenderer"][data-file-path="lib/foo.ex"]|)
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
      html = render(view)

      assert has_element?(view, "#review-packet")
      assert has_element?(view, ".review-title.is-packet-title", "Packet walkthrough")
      assert has_element?(view, ".review-packet-lede", "Read this first.")
      assert has_element?(view, ".review-header-estimate", "1 min")
      assert has_element?(view, ".review-header-change-stat .review-change-stat-add", "+1")
      assert has_element?(view, ".review-header-change-stat .review-change-stat-del", "-1")
      assert has_element?(view, "#packet-section-0.is-open")
      assert has_element?(view, "#packet-section-0 .review-packet-section-estimate", "Light")
      assert has_element?(view, "#packet-section-0 .review-change-stat-add", "+1")
      assert has_element?(view, "#packet-section-0 .review-change-stat-del", "-1")

      refute has_element?(view, "#packet-section-0 > .review-packet-section-summary-text")

      refute has_element?(
               view,
               "#packet-section-0 .review-packet-section-summary .review-packet-section-summary-text"
             )

      assert html =~ "Preserve packet JSON as the server contract."
      assert html =~ "Keep packet.md editable."
      assert html =~ "Run the smoke test"

      assert has_element?(
               view,
               "#packet-section-0-row-0 .review-packet-md-heading + .review-packet-md-paragraph",
               "Preserve packet JSON as the server contract."
             )

      assert has_element?(
               view,
               "#packet-section-0-row-0 .review-packet-md-paragraph + .review-packet-md-paragraph",
               "Keep packet.md editable."
             )

      assert has_element?(view, "#review-packet .review-hunk-card", "packet.ex")

      assert has_element?(
               view,
               ~s|#review-packet .review-hunk-toggle[title^="lib/packet.ex"]|
             )

      assert has_element?(
               view,
               ~s|#review-packet [phx-hook="DiffRenderer"][data-file-path="lib/packet.ex"]|
             )

      assert has_element?(view, "#review-packet .review-packet-md-heading", "Main change")
      assert has_element?(view, "#review-packet", "Preserve packet JSON as the server contract.")
      assert has_element?(view, "#review-packet", "Keep packet.md editable.")
      assert has_element?(view, "#review-packet", "Run the smoke test.")

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

      assert has_element?(
               view,
               ~s|#packet-section-0-row-0 .review-hunk-toggle[phx-value-hunk_id="packet-section-0-row-0--hunk-lib-packet-ex-1"]|
             )

      assert has_element?(
               view,
               ~s|#packet-section-0-row-1 .review-hunk-toggle[phx-value-hunk_id="packet-section-0-row-1--hunk-lib-packet-ex-1"]|
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

      assert has_element?(
               view,
               ~s|#packet-section-0-row-0[data-packet-row-ids="packet-section-0-row-0 packet-section-0-row-1"] .review-hunk-card|,
               "hunks 1-2"
             )

      assert has_element?(
               view,
               ~s|#packet-section-0-row-0 [id="packet-section-0-row-0--hunk-lib-packet-ex-1-through-2-diff"][phx-hook="DiffRenderer"]|
             )

      refute has_element?(view, "#packet-section-0-row-0 .review-hunk-lines")
      refute has_element?(view, "#packet-section-0-row-1 .review-hunk-card")

      refute has_element?(
               view,
               ~s|#packet-section-0-row-1 [phx-hook="DiffRenderer"]|
             )
    end

    test "opening a small packet section expands every hunk", %{conn: conn, author: author} do
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

      assert has_element?(view, "#packet-section-0:not(.is-open)")
      refute has_element?(view, ~s|#packet-section-0 [phx-hook="DiffRenderer"]|)

      view
      |> element("#packet-section-0 .review-packet-section-heading", "First section")
      |> render_click()

      assert has_element?(
               view,
               ~s|#packet-section-0 [phx-hook="DiffRenderer"][data-file-path="lib/one.ex"]|
             )

      assert has_element?(
               view,
               ~s|#packet-section-0 [phx-hook="DiffRenderer"][data-file-path="lib/two.ex"]|
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

      assert has_element?(
               changes_view,
               ~s|#diff-files .review-hunk-toggle[title^="lib/packet.ex"]|
             )

      assert has_element?(changes_view, "#diff-files .review-hunk-card")

      assert has_element?(
               changes_view,
               ~s|[phx-hook="DiffRenderer"][data-file-path="lib/packet.ex"]|
             )

      changes_view
      |> element("#diff-style-unified")
      |> render_click()

      refute has_element?(changes_view, "#file-tree")
      assert has_element?(changes_view, "#review-guide-sidebar #review-guide-rail")

      assert has_element?(
               changes_view,
               "#review-guide-rail .review-guide-rail-count",
               "1 section"
             )

      assert has_element?(changes_view, "#review-guide-rail .review-guide-rail-summary", "1 file")

      assert has_element?(
               changes_view,
               "#review-guide-rail .review-guide-section-title",
               "Main change"
             )

      assert has_element?(changes_view, "#review-guide-rail .review-guide-file-row", "packet.ex")
      assert has_element?(changes_view, "#review-guide-rail .review-guide-file-state", "1 hunk")

      refute has_element?(
               changes_view,
               ~s|#diff-files .review-hunk-summary[phx-hook="StickyHunkHeader"]|
             )

      changes_view
      |> element("#diff-style-split")
      |> render_click()

      refute has_element?(changes_view, "#file-tree")
    end

    test "unified guide rail focuses the active section overview", %{conn: conn, author: author} do
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
            "sections" => [
              %{
                "title" => "Primary reasoning",
                "rows" => [
                  %{
                    "kind" => "markdown",
                    "body" =>
                      "This first paragraph explains why the entrypoint change matters before the reviewer looks at the code."
                  },
                  %{"kind" => "hunk", "path" => "lib/first.ex", "hunk_index" => 1}
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

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}/changes")

      view
      |> element("#diff-style-unified")
      |> render_click()

      assert has_element?(view, "#review-guide-section-0.is-active")

      assert has_element?(
               view,
               "#review-guide-section-0 .review-guide-section-summary",
               "entrypoint change matters"
             )

      assert has_element?(view, "#review-guide-section-0 .review-guide-file-row", "first.ex")
      assert has_element?(view, "#review-guide-section-1 .review-guide-section-collapsed-meta")
      refute has_element?(view, "#review-guide-section-1 .review-guide-section-summary")
      refute has_element?(view, "#review-guide-section-1 .review-guide-file-row")

      view
      |> element("#review-guide-section-1 .review-guide-section-button")
      |> render_click()

      assert has_element?(view, "#review-guide-section-1.is-active")

      assert has_element?(
               view,
               "#review-guide-section-1 .review-guide-section-summary",
               "stay out of the way"
             )

      assert has_element?(view, "#review-guide-section-1 .review-guide-file-row", "second.ex")
      refute has_element?(view, "#review-guide-section-0 .review-guide-section-summary")
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
      assert has_element?(changes_view, "#diff-files .review-hunk-card.is-file-diff", "packet.ex")
      assert has_element?(changes_view, "#diff-files .review-file-view-state", "2 hunks")
      refute has_element?(changes_view, "#diff-files .review-hunk-card:not(.is-file-diff)")
      refute has_element?(changes_view, "#diff-files .review-hunk-card.is-file-diff", "hunks 1-2")

      assert has_element?(
               changes_view,
               ~s|#diff-files [id^="file-diff-"][id$="-diff"][phx-hook="DiffRenderer"][data-file-path="lib/packet.ex"]|
             )
    end

    test "keeps large diffs collapsed on the changes route", %{conn: conn, author: author} do
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

      assert has_element?(changes_view, "#diff-files .review-hunk-card.is-file-diff", "large.ex")

      refute has_element?(
               changes_view,
               ~s|#diff-files [phx-hook="DiffRenderer"][data-file-path="lib/large.ex"]|
             )
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

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}/changes")

      refute has_element?(view, "#review-guide-rail")

      view
      |> element("#diff-style-unified")
      |> render_click()

      assert has_element?(view, "#review-guide-rail")
      refute has_element?(view, ".review-outline-toggle")

      view
      |> element("#review-guide-rail .review-packet-nav-hide")
      |> render_click()

      refute has_element?(view, "#review-guide-rail")
      assert has_element?(view, ".review-outline-toggle", "Show outline")

      author = Accounts.get_user!(author.id)
      assert Accounts.get_user_preference(author, :packet_outline_visible, true) == false

      {:ok, next_view, _html} = live(conn, ~p"/r/#{packet_review.slug}/changes")

      refute has_element?(next_view, "#review-guide-rail")

      next_view
      |> element("#diff-style-unified")
      |> render_click()

      refute has_element?(next_view, "#review-guide-rail")
      assert has_element?(next_view, ".review-outline-toggle", "Show outline")
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

      packet_view
      |> element("#packet-section-0 button", "Mark Viewed")
      |> render_click()

      assert has_element?(packet_view, "#packet-section-0 .review-hunk-viewed-pill", "Viewed")
      assert has_element?(packet_view, ~s|#packet-section-0 [phx-hook="DiffRenderer"]|)

      {:ok, changes_view, _html} = live(conn, ~p"/r/#{packet_review.slug}/changes")

      assert has_element?(changes_view, "#diff-files .review-hunk-viewed-pill", "Viewed")

      changes_view
      |> element(~s|#diff-files button.review-hunk-viewed-button[phx-value-hunk_index="1"]|)
      |> render_click()

      refute has_element?(changes_view, "#diff-files .review-hunk-viewed-pill", "Viewed")

      {:ok, packet_view_after_clear, _html} = live(conn, ~p"/r/#{packet_review.slug}")

      refute has_element?(
               packet_view_after_clear,
               "#packet-section-0 .review-hunk-viewed-pill",
               "Viewed"
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

      packet_view
      |> element("#packet-section-0 button", "Mark Viewed")
      |> render_click()

      assert has_element?(packet_view, "#packet-section-0 .review-hunk-viewed-pill", "Viewed")
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

      packet_view
      |> element("#packet-section-0 button", "Mark Viewed")
      |> render_click()

      assert has_element?(packet_view, "#packet-section-0 .review-hunk-viewed-pill", "Viewed")

      {:ok, changes_view, _html} = live(conn, ~p"/r/#{packet_review.slug}/changes")
      assert has_element?(changes_view, "#diff-files .review-hunk-viewed-pill", "Viewed")

      [cleared_view | _] = PacketHunkViews.list_for_review(packet_review, author)
      attrs = Map.take(cleared_view, [:file_path, :row_ref, :hunk_fingerprint])
      {:ok, _} = PacketHunkViews.clear_viewed(packet_review, author, attrs)

      {:ok, packet_view_after_clear, _html} = live(conn, ~p"/r/#{packet_review.slug}")

      assert has_element?(
               packet_view_after_clear,
               "#packet-section-0 .review-hunk-partial-pill",
               "Partially viewed"
             )

      assert has_element?(packet_view_after_clear, "#packet-section-0 button", "Mark Viewed")
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
      assert has_element?(view, "#packet-section-0.is-open")

      view |> element("#packet-section-0 button", "Approve") |> render_click()
      assert has_element?(view, "#packet-section-0:not(.is-open)")

      refute has_element?(view, "#packet-section-0 .review-section-state-pill.is-current")
      assert has_element?(view, "#packet-section-0 .review-section-action.is-active", "Approve")

      view |> element("#packet-section-0 button", "Approve") |> render_click()
      assert has_element?(view, "#packet-section-0:not(.is-open)")
      refute has_element?(view, "#packet-section-0 .review-section-action.is-active")

      view |> element("#packet-section-0 button", "Approve") |> render_click()
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
      refute has_element?(latest_view, "#packet-section-0 .review-section-action.is-active")

      assert has_element?(
               latest_view,
               ~s|#packet-section-0 .review-section-state-pill.is-previous.is-approved[title="Previously approved in v1"]|
             )

      refute has_element?(
               latest_view,
               "#packet-section-0 a.review-section-state-pill.is-previous"
             )

      assert has_element?(latest_view, "#packet-section-0 .review-section-transition-icon")
      assert has_element?(latest_view, "#packet-section-0 .review-packet-section-actions")
      assert has_element?(latest_view, "#packet-section-0.is-open")

      latest_view |> element("#packet-section-0 button", "Ignore") |> render_click()

      assert has_element?(
               latest_view,
               ~s|#packet-section-0 .review-section-state-pill.is-previous.is-approved[title="Previously approved in v1"]|
             )

      refute has_element?(latest_view, "#packet-section-0 .review-section-state-pill.is-current")

      assert has_element?(
               latest_view,
               "#packet-section-0 .review-section-action.is-active",
               "Ignore"
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

      assert has_element?(
               carried_view,
               "#packet-section-0 .review-section-action.is-active",
               "Ignore"
             )

      refute has_element?(
               carried_view,
               "#packet-section-0 .review-section-state-pill.is-previous"
             )

      carried_view |> element("#packet-section-0 button", "Ignore") |> render_click()
      refute has_element?(carried_view, "#packet-section-0 .review-section-action.is-active")
    end
  end
end
