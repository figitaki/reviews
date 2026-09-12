defmodule Reviews.DemoCatalog do
  @moduledoc """
  Versioned sample reviews and the demo hub's manual QA checklist.
  Existing samples are preserved on deploy so visitors' discussions survive.
  Bump a sample's slug when changing its fixtures.
  """
  alias Reviews.Repo
  alias Reviews.Reviews, as: ReviewContext

  def scenarios do
    [
      %{
        id: "markdown",
        slug: "demo-markdown-v1",
        title: "Markdown documents",
        description:
          "Compare rendered documents, added files, deleted files, and partial patches.",
        checks: [
          "Switch between Source and Preview",
          "Inspect headings, lists, tables, quotes, links, and code fences",
          "Compare Before and After excerpts",
          "Open the complete added document and the deleted document",
          "Confirm raw HTML displays as text"
        ]
      },
      %{
        id: "workflow",
        slug: "demo-workflow-v1",
        title: "Review workflow",
        description: "Two revisions, a structured packet, and open and resolved discussions.",
        checks: [
          "Switch between revisions 1 and 2",
          "Switch between Packet and Changes",
          "Expand and collapse hunks and navigate the outline",
          "Inspect open and resolved discussions",
          "Sign in to comment, reply, mark viewed, and decide a section"
        ]
      },
      %{
        id: "files",
        slug: "demo-files-v1",
        title: "File changes",
        description: "Added, deleted, renamed, modified, and binary files in one review.",
        checks: [
          "Navigate every file in the tree",
          "Compare split and unified source layouts",
          "Inspect file status and change counts",
          "Check renamed and binary file fallback states"
        ]
      },
      %{
        id: "large",
        slug: "demo-large-v1",
        title: "Large diffs",
        description: "A 1,650-line added file exercises scrolling and virtualized rendering.",
        checks: [
          "Scroll from the first line to the last",
          "Switch split and unified layouts",
          "Sign in and comment near the end of the file",
          "Check narrow-screen scrolling and sticky headers"
        ]
      }
    ]
  end

  def seed!(author) do
    Enum.map(scenarios(), fn scenario ->
      # One transaction prevents partially seeded revisions or discussions.
      {:ok, review} =
        Repo.transaction(fn ->
          ReviewContext.get_review_by_slug(scenario.slug) || create!(author, scenario)
        end)

      review
    end)
  end

  defp create!(author, scenario) do
    raw = fixture(scenario.id, 1)

    {:ok, %{review: review}} =
      ReviewContext.create_review_with_initial_patchset(author, %{
        slug: scenario.slug,
        title: scenario.title,
        description: scenario.description,
        raw_diff: raw,
        packet: packet(scenario, raw),
        branch_name: "demo/#{scenario.id}"
      })

    if scenario.id == "workflow" do
      raw = fixture("workflow", 2)

      {:ok, _} =
        ReviewContext.append_patchset(review, %{raw_diff: raw, packet: packet(scenario, raw)})

      seed_discussions!(review, author)
    end

    review
  end

  defp packet(%{id: "files"}, _raw), do: nil

  defp packet(scenario, raw) do
    %{
      "format_version" => 1,
      "title" => scenario.title,
      "summary" => scenario.description <> "\n\n[Back to Demo & QA](/demo)",
      "sections" => [
        %{
          "title" => "Try this review",
          "rows" =>
            [
              %{
                "kind" => "markdown",
                "body" => Enum.map_join(scenario.checks, "\n", &("- " <> &1))
              }
            ] ++
              Enum.flat_map(ReviewContext.parse_diff_files(raw), fn file ->
                Regex.scan(~r/^@@ /m, file.raw_diff)
                |> Enum.with_index(1)
                |> Enum.map(fn {_, index} ->
                  %{"kind" => "hunk", "path" => file.path, "hunk_index" => index}
                end)
              end)
        }
      ]
    }
  end

  defp fixture("large", _) do
    lines = Enum.map_join(1..1650, "\n", &"+export const sample#{&1} = #{&1};")

    "diff --git a/large.js b/large.js\nnew file mode 100644\n--- /dev/null\n+++ b/large.js\n@@ -0,0 +1,1650 @@\n#{lines}\n"
  end

  defp fixture(id, revision) do
    name = if id == "workflow", do: "workflow-#{revision}", else: id

    :reviews
    |> :code.priv_dir()
    |> List.to_string()
    |> Path.join("examples/demo/#{name}.patch")
    |> File.read!()
  end

  defp seed_discussions!(review, user) do
    {:ok, identity} = Reviews.Accounts.ensure_human_identity(user)

    for {status, line, body} <- [
          {"open", 3, "Try replying here. Should whitespace-only names have a fallback?"},
          {"resolved", 4,
           "The greeting now uses the normalized name. This sample discussion is resolved."}
        ] do
      thread =
        %Reviews.Threads.Thread{}
        |> Reviews.Threads.Thread.changeset(%{
          review_id: review.id,
          originating_patchset_id: ReviewContext.latest_patchset_id(review),
          author_id: identity.id,
          file_path: "lib/greeting.ex",
          side: "new",
          status: status,
          anchor: %{"granularity" => "line", "line_number_hint" => line}
        })
        |> Repo.insert!()

      %Reviews.Threads.Comment{}
      |> Reviews.Threads.Comment.changeset(%{
        thread_id: thread.id,
        author_id: identity.id,
        body: body
      })
      |> Repo.insert!()
    end
  end
end
