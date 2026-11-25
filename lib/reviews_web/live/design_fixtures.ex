defmodule ReviewsWeb.DesignFixtures do
  @moduledoc """
  Sample threads for the component playground (`/design/components`).

  They are the real schema structs, not hand-written JSON, so the thread
  payload and the activity log come out of the same code the review page
  uses. Nothing here touches the database.
  """

  alias Reviews.Accounts.Identity
  alias Reviews.Threads.{Comment, Thread}

  @file_path "lib/reviews/threads.ex"

  def file_path, do: @file_path

  def review, do: %{id: 0, slug: "design"}

  @doc "Threads in every state the review page shows."
  def threads(now \\ DateTime.utc_now()) do
    carey = identity(1, "carey", "Carey")
    sam = identity(2, "sam", "Sam")
    agent = %{identity(3, "claude", "Claude") | kind: "agent"}

    [
      thread(101, "open", 42, "new", carey, [
        comment(1001, carey, ago(now, 26 * 60), """
        Should this retry when the anchor moves? Today it gives up on the
        first `{:error, :outdated}`.
        """),
        comment(1002, sam, ago(now, 18 * 60), "Once, then mark it outdated. I'll add a test."),
        comment(1003, sam, ago(now, 17 * 60), "Pushed in v3."),
        comment(1004, agent, ago(now, 4 * 60), "The new test covers both sides of the move.",
          attribution: %{
            "provider" => "poppy",
            "client_id" => "https://agent.example.dev/client",
            "client_name_claimed" => "Claude",
            "owner_username" => "carey",
            "approved_at" => "2026-11-01T12:00:00Z",
            "access_token_dpop_key" => "jkt"
          }
        )
      ]),
      thread(102, "resolved", 41, "old", sam, [
        comment(1005, sam, ago(now, 3 * 86_400), "This import is unused."),
        comment(1006, carey, ago(now, 3 * 86_400 - 600), "Removed, thanks.")
      ])
      |> Map.merge(%{resolved_by: carey, resolved_at: ago(now, 3 * 86_400 - 600)}),
      thread(103, "open", 44, "new", carey, [
        comment(1007, carey, ago(now, 90), "Nit: `relocate/3` reads better than `move/3`.")
      ])
    ]
  end

  @diff """
  diff --git a/lib/reviews/threads.ex b/lib/reviews/threads.ex
  --- a/lib/reviews/threads.ex
  +++ b/lib/reviews/threads.ex
  @@ -38,6 +38,9 @@ defmodule Reviews.Threads do
     def relocate(thread, patchset, opts \\\\ []) do
  -    case Anchoring.relocate(thread.anchor, patchset) do
  +    retries = Keyword.get(opts, :retries, 1)
  +
  +    case Anchoring.relocate(thread.anchor, patchset) do
         {:ok, anchor} -> update_anchor(thread, anchor)
  -      {:error, :outdated} -> mark_outdated(thread)
  +      {:error, :outdated} when retries > 0 -> relocate(thread, patchset, retries: retries - 1)
  +      {:error, :outdated} -> mark_outdated(thread)
       end
     end
  """

  @doc "The changed file the sample threads sit on, shaped like the review page's file diffs."
  def file do
    %{id: 1, path: @file_path, status: "modified", raw_diff: @diff}
  end

  @doc "One hunk of `file/0`, shaped like `Reviews.ReviewHunks` output."
  def hunk(viewed? \\ false) do
    %{
      file_path: @file_path,
      display_raw_diff: @diff,
      hunk_header: "@@ -38,6 +38,9 @@",
      hunk_index: 1,
      line_start: 38,
      line_end: 46,
      display_additions: count_lines(@diff, "+"),
      display_deletions: count_lines(@diff, "-"),
      row_ref: "design-row-1",
      hunk_fingerprint: "design",
      viewed?: viewed?
    }
  end

  # Changed lines in a unified diff, without the ---/+++ file headers.
  defp count_lines(diff, sign) do
    diff
    |> String.split("\n")
    |> Enum.count(
      &(String.starts_with?(&1, sign) and not String.starts_with?(&1, sign <> sign <> sign))
    )
  end

  @doc "The signed-in viewer for the app shell and new comments."
  def viewer, do: %{identity(4, "you", "You") | avatar_url: nil} |> Map.put(:username, "you")

  @doc "Named reviewers: one who has signed up, one still invited."
  def reviewers(now \\ DateTime.utc_now()) do
    [
      %{
        github_id: 2,
        login: "sam",
        status: "active",
        identity: identity(2, "sam", "Sam"),
        added_at: now
      },
      %{github_id: 9, login: "riley", status: "invited", identity: nil, added_at: now}
    ]
  end

  @doc "A packet section in each decision state."
  def section(index, status, title) do
    %{
      index: index,
      title: title,
      status: status,
      effective_status: status,
      decision_history: if(status != "pending", do: "Decided by @carey on v3.")
    }
  end

  @doc """
  A section as its header renders it, in one of the review states a reader
  sees: decided on this revision, carried forward from an earlier one, or
  pending again because the section changed.
  """
  def section_header(index, state, title) do
    {status, effective, previous} =
      case state do
        :decided -> {"approved", "approved", nil}
        :carried -> {nil, "approved", nil}
        :outdated -> {nil, nil, %{status: "approved", patchset_number: 2}}
        :pending -> {nil, nil, nil}
      end

    %{
      index: index,
      title: title,
      status: status,
      effective_status: effective,
      previous: previous,
      decision_history: previous && "Previously approved in v2; outdated for v3.",
      estimate: %{
        effort: "Small",
        hunk_count: 3,
        additions: 24,
        deletions: 6,
        time: "5 min",
        viewed_count: 1
      }
    }
  end

  @doc """
  Applies a `create_comment` payload from the diff to the sample threads, as
  the review page would after saving it: a reply joins its thread, anything
  else starts one.
  """
  def add_comment(threads, %{"body" => body} = params, author, now \\ DateTime.utc_now()) do
    next_id =
      Enum.max(Enum.flat_map(threads, &[&1.id | Enum.map(&1.comments, fn c -> c.id end)])) + 1

    comment = comment(next_id, author, DateTime.truncate(now, :second), body)

    case Enum.find(threads, &(&1.id == params["thread_id"])) do
      nil ->
        new =
          thread(
            next_id,
            "open",
            params["thread_anchor"]["line_number_hint"],
            params["side"],
            author,
            [
              comment
            ]
          )
          |> Map.put(:anchor, params["thread_anchor"])

        threads ++ [new]

      thread ->
        Enum.map(threads, fn
          %{id: id} = t when id == thread.id -> %{t | comments: t.comments ++ [comment]}
          t -> t
        end)
    end
  end

  @doc "Sets a sample thread's status, as `update_thread_status` would."
  def set_status(threads, id, status) do
    Enum.map(threads, fn
      %{id: ^id} = t -> %{t | status: status}
      t -> t
    end)
  end

  defp identity(id, handle, name) do
    %Identity{id: id, kind: "human", handle: handle, display_name: name, avatar_url: nil}
  end

  defp thread(id, status, line, side, author, comments) do
    %Thread{
      id: id,
      file_path: @file_path,
      side: side,
      anchor: %{"granularity" => "line", "line_number_hint" => line},
      status: status,
      author: author,
      author_id: author.id,
      inserted_at: hd(comments).inserted_at,
      comments: comments
    }
    # Set on loaded threads by the review page's projection.
    |> Map.merge(%{can_update_status: true, originating_patchset_number: 3})
  end

  defp comment(id, author, at, body, opts \\ []) do
    %Comment{
      id: id,
      body: String.trim(body),
      author: author,
      author_id: author.id,
      attribution: opts[:attribution],
      inserted_at: at,
      updated_at: at
    }
  end

  defp ago(now, seconds), do: now |> DateTime.add(-seconds) |> DateTime.truncate(:second)

  @tree_files [
    {"assets/css/packet.css", "modified", 214, 61},
    {"assets/css/tokens.css", "modified", 3, 1},
    {"assets/js/hooks/guide_flyout.js", "added", 53, 0},
    {"lib/reviews_web/live/review_live/diff_components.ex", "modified", 96, 4},
    {"lib/reviews_web/live/review_live/old_outline.ex", "deleted", 0, 38},
    {"lib/reviews_web/live/review_live/guide_outline.ex", "renamed", 2, 2},
    {"mix.exs", "modified", 1, 1}
  ]

  @doc "Changed files for the diff view's file tree, shaped like the review page's file diffs."
  def tree_files do
    @tree_files
    |> Enum.with_index(1)
    |> Enum.map(fn {{path, status, additions, deletions}, id} ->
      %{id: id, path: path, status: status, additions: additions, deletions: deletions}
    end)
  end

  @doc """
  A Guide map outline with decided and undecided sections. `offset` keeps
  section ids unique when the catalog renders it once per theme.
  """
  def guide_outline(offset \\ 0) do
    files = tree_files()

    sections =
      [
        {"Tree row styles", "approved", Enum.slice(files, 0, 2)},
        {"File tree in the diff view", nil, Enum.slice(files, 2, 4)},
        {"Guide map rows", "denied", Enum.slice(files, 6, 1)},
        {"Release notes", "ignored", []}
      ]
      |> Enum.with_index(offset)
      |> Enum.map(fn {{title, status, section_files}, index} ->
        %{
          index: index,
          title: title,
          effective_status: status,
          target_id: "dcp-tree-section-#{index}",
          files: Enum.map(section_files, &outline_file(&1, index))
        }
      end)

    %{
      sections: sections,
      summary: %{
        additions: Enum.sum(Enum.map(files, & &1.additions)),
        deletions: Enum.sum(Enum.map(files, & &1.deletions)),
        file_count: length(files)
      }
    }
  end

  defp outline_file(file, index) do
    %{
      path: file.path,
      basename: Path.basename(file.path),
      directory: Path.dirname(file.path) |> String.replace_prefix(".", ""),
      status: file.status,
      additions: file.additions,
      deletions: file.deletions,
      target_id: "dcp-tree-section-#{index}-#{file.id}"
    }
  end
end
