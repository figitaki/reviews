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
            "invariants" => [
              %{
                "kind" => "markdown",
                "body" =>
                  "- Preserve packet JSON as the server contract.\n- Keep packet.md editable."
              }
            ],
            "tour" => [
              %{"kind" => "markdown", "body" => "### Main change\nStart here."},
              %{"kind" => "hunk", "path" => "lib/packet.ex"}
            ],
            "tasks" => [
              %{"key" => "smoke", "description" => "Run the smoke test"}
            ],
            "open_questions" => [
              %{"key" => "decision", "body" => "Is this the right direction?"}
            ]
          }
        })

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}")
      html = render(view)

      assert has_element?(view, "#review-packet")
      assert has_element?(view, ".review-title.is-packet-title", "Packet walkthrough")
      assert has_element?(view, ".review-packet-lede", "Read this first.")
      assert html =~ "Preserve packet JSON as the server contract."
      assert html =~ "Keep packet.md editable."
      assert html =~ "Run the smoke test"
      assert html =~ "Is this the right direction?"
      refute html =~ "### Main change"

      assert has_element?(
               view,
               ~s|#review-packet [phx-hook="DiffRenderer"][data-file-path="lib/packet.ex"]|
             )

      assert has_element?(view, "#review-packet .review-packet-md-heading", "Main change")
    end

    test "renders round and turn navigation from packet-bearing patchsets", %{
      conn: conn,
      author: author
    } do
      {:ok, %{review: packet_review}} =
        ReviewsCtx.create_review_with_initial_patchset(author, %{
          title: "Round nav",
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
            "title" => "First packet"
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
            "title" => "Second packet"
          }
        })

      {:ok, view, _html} = live(conn, ~p"/r/#{packet_review.slug}")

      assert has_element?(view, "#revision-nav", "Round 2 of 2")
      assert has_element?(view, "#revision-nav", "Second packet")
      assert has_element?(view, ".review-header-meta", "Turn v3")
      assert has_element?(view, ".review-header-meta", "+1 -1")
      assert has_element?(view, ~s|#revision-nav .review-round-chip.is-active|, "2")
      assert has_element?(view, ~s|#revision-nav #patchset-3.is-active|, "v3")
    end

    test "Publish review button is disabled with no drafts", %{conn: conn, review: review} do
      {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}")
      assert has_element?(view, "#publish-review-button[disabled]")
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
  end
end
