defmodule ReviewsWeb.GeneratedFilesTest do
  use ReviewsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Reviews.Reviews, as: ReviewsCtx

  @diff """
  diff --git a/Cargo.lock b/Cargo.lock
  --- a/Cargo.lock
  +++ b/Cargo.lock
  @@ -1 +1 @@
  -version = 1
  +version = 2
  diff --git a/lib/app.ex b/lib/app.ex
  --- a/lib/app.ex
  +++ b/lib/app.ex
  @@ -1 +1 @@
  -def a, do: :old
  +def a, do: :new
  diff --git a/vendor/lib.js b/vendor/lib.js
  --- a/vendor/lib.js
  +++ b/vendor/lib.js
  @@ -1 +1 @@
  -var a = 1
  +var a = 2
  """

  setup do
    author = Reviews.ReviewIndexFixtures.user!("generated-author")

    {:ok, %{review: review}} =
      ReviewsCtx.create_review_with_initial_patchset(author, %{
        title: "Generated files",
        raw_diff: @diff,
        file_attributes: [
          %{"path" => "Cargo.lock", "generated" => true, "vendored" => false},
          %{"path" => "vendor/lib.js", "generated" => false, "vendored" => true},
          # Paths that are not in the diff and malformed entries are ignored.
          %{"path" => "missing.lock", "generated" => true},
          "not a map"
        ],
        packet: %{
          "title" => "Packet",
          "sections" => [
            %{
              "title" => "Everything",
              "rows" =>
                for(
                  path <- ["lib/app.ex", "Cargo.lock", "vendor/lib.js"],
                  do: %{"kind" => "hunk", "path" => path, "hunk_index" => 1}
                )
            }
          ]
        }
      })

    %{review: review}
  end

  defp island(path), do: ~s|[phx-hook="DiffRenderer"][data-file-path="#{path}"]|

  test "the push stores the flags per file", %{review: review} do
    flags =
      review
      |> ReviewsCtx.latest_patchset()
      |> ReviewsCtx.list_files()
      |> Map.new(&{&1.path, {&1.generated, &1.vendored}})

    assert flags == %{
             "Cargo.lock" => {true, false},
             "lib/app.ex" => {false, false},
             "vendor/lib.js" => {false, true}
           }
  end

  test "an opened section leaves generated and vendored files collapsed and labelled",
       %{conn: conn, review: review} do
    {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}")
    view |> element("#review-guide-tick-0") |> render_click()

    assert has_element?(view, "#packet-section-0.is-open")
    assert has_element?(view, island("lib/app.ex") <> ~s|[data-hunk-expanded="true"]|)
    assert has_element?(view, island("Cargo.lock") <> ~s|[data-hunk-expanded="false"]|)
    assert has_element?(view, island("vendor/lib.js") <> ~s|[data-hunk-expanded="false"]|)

    assert has_element?(view, island("Cargo.lock") <> ~s|[data-hunk-label^="Generated file"]|)
    assert has_element?(view, island("vendor/lib.js") <> ~s|[data-hunk-label^="Vendored file"]|)
    refute has_element?(view, island("lib/app.ex") <> ~s|[data-hunk-label*="file"]|)
  end

  test "the changes view opens only the other files, and a click opens a generated one",
       %{conn: conn, review: review} do
    {:ok, view, _html} = live(conn, ~p"/r/#{review.slug}/changes")

    assert has_element?(view, island("lib/app.ex") <> ~s|[data-hunk-expanded="true"]|)
    assert has_element?(view, island("Cargo.lock") <> ~s|[data-hunk-expanded="false"]|)
    assert has_element?(view, island("Cargo.lock") <> ~s|[data-hunk-label="Generated file"]|)

    file = review |> ReviewsCtx.latest_patchset() |> ReviewsCtx.list_files(["Cargo.lock"]) |> hd()
    render_click(view, "toggle_hunk_diff", %{"hunk_id" => "file-diff-#{file.id}"})

    assert has_element?(view, island("Cargo.lock") <> ~s|[data-hunk-expanded="true"]|)
  end
end
