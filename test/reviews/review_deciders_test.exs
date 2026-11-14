defmodule Reviews.ReviewDecidersTest do
  use Reviews.DataCase, async: true

  alias Reviews.Accounts
  alias Reviews.PacketSectionDecisions
  alias Reviews.ReviewDeciders
  alias Reviews.ReviewPacket
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads

  @diff_v1 """
  diff --git a/lib/a.ex b/lib/a.ex
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -1 +1 @@
  -old
  +new
  diff --git a/lib/b.ex b/lib/b.ex
  --- a/lib/b.ex
  +++ b/lib/b.ex
  @@ -1 +1 @@
  -old
  +new
  """

  defp user!(name) do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: name,
        email: "#{name}@example.com",
        avatar_url: nil
      })

    user
  end

  defp identity!(user) do
    {:ok, identity} = Accounts.ensure_human_identity(user)
    identity
  end

  defp packet(b_line_end \\ 2) do
    %{
      "format_version" => 1,
      "title" => "Two sections",
      "sections" => [
        %{
          "title" => "Section A",
          "rows" => [
            %{
              "kind" => "hunk",
              "path" => "lib/a.ex",
              "hunk_index" => 1,
              "line_start" => 1,
              "line_end" => 2
            }
          ]
        },
        %{
          "title" => "Section B",
          "rows" => [
            %{
              "kind" => "hunk",
              "path" => "lib/b.ex",
              "hunk_index" => 1,
              "line_start" => 1,
              "line_end" => b_line_end
            }
          ]
        }
      ]
    }
  end

  defp packet_review!(author) do
    {:ok, %{review: review, patchset: patchset}} =
      ReviewsContext.create_review_with_initial_patchset(author, %{
        title: "Packet review",
        raw_diff: @diff_v1,
        packet: packet()
      })

    %{review: review, patchset: patchset}
  end

  defp decide!(review, patchset, identity, section_index, status) do
    section = ReviewPacket.section_at(patchset.packet, section_index)

    {:ok, _} =
      PacketSectionDecisions.set_status(review, patchset, identity, %{
        section_index: section.index,
        section_title: section.title,
        section_fingerprint: section.fingerprint,
        section_refs: section.refs,
        status: status
      })
  end

  defp comment!(review, identity, body) do
    {:ok, _} =
      Threads.publish_comment(review, identity, %{
        "file_path" => "lib/a.ex",
        "side" => "new",
        "body" => body,
        "thread_anchor" => %{
          "granularity" => "line",
          "line_text" => "new",
          "context_before" => [],
          "context_after" => [],
          "line_number_hint" => 1
        }
      })
  end

  defp deciders(review) do
    review = ReviewsContext.get_review_by_slug(review.slug)
    patchsets = ReviewsContext.list_patchsets(review)
    ReviewDeciders.list(review, patchsets, List.last(patchsets))
  end

  defp by_handle(deciders), do: Map.new(deciders, &{&1.author.handle, &1})

  test "rolls section decisions up to one decision per reviewer" do
    author = user!("author")
    %{review: review, patchset: ps} = packet_review!(author)

    approver = identity!(user!("approver"))
    denier = identity!(user!("denier"))
    halfway = identity!(user!("halfway"))
    skipper = identity!(user!("skipper"))

    decide!(review, ps, approver, 0, "approved")
    decide!(review, ps, approver, 1, "ignored")
    decide!(review, ps, denier, 0, "approved")
    decide!(review, ps, denier, 1, "denied")
    decide!(review, ps, halfway, 0, "approved")
    decide!(review, ps, skipper, 0, "ignored")
    decide!(review, ps, skipper, 1, "ignored")

    deciders = by_handle(deciders(review))

    assert %{decision: "approved", approved: 1, ignored: 1, section_count: 2} =
             deciders["approver"]

    assert %{decision: "denied", denied: 1, approved: 1} = deciders["denier"]
    assert %{decision: "in_progress", approved: 1} = deciders["halfway"]
    assert %{decision: "ignored", ignored: 2} = deciders["skipper"]
  end

  test "includes agent identities and comment-only reviewers, and skips the review author" do
    author = user!("author")
    %{review: review, patchset: ps} = packet_review!(author)

    {:ok, agent} =
      Accounts.create_agent_identity(user!("agent-owner"), %{
        display_name: "Codex",
        handle: "codex",
        avatar_url: "https://example.com/codex.png"
      })

    commenter = identity!(user!("commenter"))

    decide!(review, ps, agent, 0, "approved")
    decide!(review, ps, agent, 1, "approved")
    comment!(review, agent, "looks right")
    comment!(review, commenter, "one question")
    comment!(review, commenter, "and another")

    decide!(review, ps, identity!(author), 0, "approved")
    comment!(review, author, "author reply")

    deciders = by_handle(deciders(review))

    assert Map.keys(deciders) |> Enum.sort() == ["codex", "commenter"]

    assert %{
             decision: "approved",
             comment_count: 1,
             author: %{kind: "agent", avatar_url: "https://example.com/codex.png"}
           } = deciders["codex"]

    assert %{decision: "commented", comment_count: 2, author: %{kind: "human"}} =
             deciders["commenter"]
  end

  test "carries decisions forward to unchanged sections and marks stale ones pending" do
    author = user!("author")
    %{review: review, patchset: ps1} = packet_review!(author)

    carried = identity!(user!("carried"))
    stale = identity!(user!("stale"))

    decide!(review, ps1, carried, 0, "approved")
    decide!(review, ps1, stale, 1, "approved")

    {:ok, _ps2} =
      ReviewsContext.append_patchset(review, %{
        raw_diff: @diff_v1 <> "\n",
        packet: packet(3)
      })

    deciders = by_handle(deciders(review))

    assert %{decision: "in_progress", approved: 1} = deciders["carried"]
    assert %{decision: "pending", approved: 0} = deciders["stale"]
  end

  test "drops reviewers whose only rows are cleared decisions" do
    author = user!("author")
    %{review: review, patchset: ps} = packet_review!(author)

    decide!(review, ps, identity!(user!("cleared")), 0, "pending")

    assert deciders(review) == []
  end
end
