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
      thread(102, "resolved", 7, "old", sam, [
        comment(1005, sam, ago(now, 3 * 86_400), "This import is unused."),
        comment(1006, carey, ago(now, 3 * 86_400 - 600), "Removed, thanks.")
      ])
      |> Map.merge(%{resolved_by: carey, resolved_at: ago(now, 3 * 86_400 - 600)}),
      thread(103, "open", 88, "new", carey, [
        comment(1007, carey, ago(now, 90), "Nit: `relocate/3` reads better than `move/3`.")
      ])
    ]
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
end
