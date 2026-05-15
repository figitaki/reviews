defmodule ReviewsWeb.ReviewLiveTest do
  use ReviewsWeb.ConnCase

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  alias Reviews.Accounts
  alias Reviews.Reviews, as: ReviewsCtx
  alias Reviews.Repo
  alias Reviews.Threads
  alias Reviews.Threads.Comment

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

    test "renders the review screen with file tree + diff hooks", %{conn: conn, review: review} do
      {:ok, _view, html} = live(conn, ~p"/r/#{review.slug}")

      assert html =~ "Great change"
      assert html =~ "lib/foo.ex"
      assert html =~ "phx-hook=\"DiffRenderer\""
      assert html =~ "data-file-path=\"lib/foo.ex\""
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
      assert has_element?(view, ".review-header-estimate", "Estimated Review Time")
      assert has_element?(view, ".review-header-change-stat .review-change-stat-add", "+1")
      assert has_element?(view, ".review-header-change-stat .review-change-stat-del", "-1")
      assert has_element?(view, "#packet-section-0:not([open])")
      assert has_element?(view, "#packet-section-0 .review-packet-section-estimate", "Light")
      assert has_element?(view, "#packet-section-0 .review-change-stat-add", "+1")
      assert has_element?(view, "#packet-section-0 .review-change-stat-del", "-1")

      assert has_element?(
               view,
               "#packet-section-0 .review-packet-section-summary-text",
               "Preserve packet JSON as the server contract."
             )

      assert html =~ "Preserve packet JSON as the server contract."
      assert html =~ "Keep packet.md editable."
      assert html =~ "Run the smoke test"
      refute html =~ "### Main change"

      assert has_element?(
               view,
               ~s|#review-packet [phx-hook="DiffRenderer"][data-file-path="lib/packet.ex"]|
             )

      assert has_element?(view, "#review-packet .review-packet-md-heading", "Main change")
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
      assert has_element?(view, ".review-header-meta", "Revision v3")
      assert has_element?(view, ".review-header-meta", "+1 -1")
      assert has_element?(view, ~s|#revision-nav #patchset-3.is-active|, "v3")
      assert has_element?(view, ~s|#revision-nav #patchset-1.has-packet|)
      assert has_element?(view, ~s|#revision-nav #patchset-3.has-packet|)
    end

    test "Publish review button is disabled with no drafts", %{conn: conn, review: review} do
      {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}")
      assert has_element?(view, "#publish-review-button[disabled]")
    end

    test "renders the classic diff on the changes route", %{conn: conn, author: author} do
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
      refute has_element?(packet_view, "#diff-files")

      {:ok, changes_view, _html} = live(conn, ~p"/r/#{packet_review.slug}/changes")
      assert has_element?(changes_view, "#diff-files")
      assert has_element?(changes_view, "#diff-files details.rev-file-card[open]")
      assert has_element?(changes_view, "#diff-files summary.rev-file-summary", "lib/packet.ex")

      assert has_element?(
               changes_view,
               ~s|[phx-hook="DiffRenderer"][data-file-path="lib/packet.ex"]|
             )
    end
  end

  describe "signed-in reviewer" do
    setup :seed!

    setup %{author: author, conn: conn} do
      conn = Plug.Test.init_test_session(conn, %{current_user_id: author.id})
      %{conn: conn}
    end

    test "publishing drafts marks them published and shows toast", %{
      conn: conn,
      author: author,
      review: review
    } do
      {:ok, _} =
        Threads.save_draft(review, author, %{
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

      # Publish button should be enabled with 1 draft and reflect the count.
      refute has_element?(view, "#publish-review-button[disabled]")
      assert render(view) =~ "Publish (1)"

      # Open the modal, then publish.
      view |> element("#publish-review-button") |> render_click()
      assert render(view) =~ "Overall review summary"

      view |> element("button", "Publish 1 comment") |> render_click()

      # Comment is now published.
      [thread] = Threads.list_published_threads(review.id)
      [comment] = thread.comments
      assert comment.state == "published"
      assert comment.body == "what about :renamed?"
    end

    test "save_draft event persists via Threads.save_draft", %{
      conn: conn,
      review: review
    } do
      {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}")

      render_hook(view, "save_draft", %{
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

      seeded_drafts = Repo.all(from c in Comment, where: c.state == "draft")

      assert length(seeded_drafts) == 1
      assert hd(seeded_drafts).body == "from-hook"
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
      view |> element("#packet-section-0 button", "Approve") |> render_click()
      assert has_element?(view, ~s|#packet-section-0:not([open])|)

      refute has_element?(view, "#packet-section-0 .review-section-state-pill.is-current")
      assert has_element?(view, "#packet-section-0 .review-section-action.is-active", "Approve")

      view |> element("#packet-section-0 button", "Approve") |> render_click()
      assert has_element?(view, ~s|#packet-section-0:not([open])|)
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
      assert has_element?(latest_view, ~s|#packet-section-0:not([open])|)

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
