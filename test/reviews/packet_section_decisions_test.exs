defmodule Reviews.PacketSectionDecisionsTest do
  use Reviews.DataCase, async: true

  alias Reviews.Accounts
  alias Reviews.PacketSectionDecisions
  alias Reviews.ReviewPacket
  alias Reviews.Reviews, as: ReviewsContext

  @diff_v1 """
  diff --git a/foo b/foo
  --- a/foo
  +++ b/foo
  @@ -1 +1 @@
  -old
  +new
  diff --git a/bar b/bar
  --- a/bar
  +++ b/bar
  @@ -1 +1 @@
  -old
  +new
  """

  @diff_v2 @diff_v1 <>
             """
             diff --git a/baz b/baz
             --- a/baz
             +++ b/baz
             @@ -1 +1 @@
             -old
             +new
             """

  defp packet(bar_paths) do
    %{
      "format_version" => 1,
      "title" => "Packet",
      "sections" => [
        %{"title" => "Foo", "rows" => [%{"kind" => "hunk", "path" => "foo", "hunk_index" => 1}]},
        %{
          "title" => "Bar",
          "rows" =>
            for(path <- bar_paths, do: %{"kind" => "hunk", "path" => path, "hunk_index" => 1})
        }
      ]
    }
  end

  setup do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: "decider",
        email: "decider@example.com",
        avatar_url: nil
      })

    {:ok, agent} = Accounts.create_agent_identity(user, %{display_name: "Codex", handle: "codex"})

    {:ok, %{review: review, patchset: v1}} =
      ReviewsContext.create_review_with_initial_patchset(agent, %{
        title: "Decisions",
        raw_diff: @diff_v1,
        packet: packet(["bar"])
      })

    %{user: user, agent: agent, review: review, v1: v1}
  end

  defp decide(review, patchset, actor, index, status) do
    section = ReviewPacket.section_at(patchset.packet, index)
    {:ok, _} = PacketSectionDecisions.decide(review, patchset, actor, section, status)
  end

  defp by_section(review, patchset),
    do:
      PacketSectionDecisions.by_section(
        review,
        ReviewPacket.sections(patchset.packet),
        patchset,
        ReviewsContext.list_patchsets(review)
      )

  test "a fresh decision names its author and patchset", %{review: review, v1: v1, agent: agent} do
    decide(review, v1, agent, 0, "approved")

    assert [
             %{index: 0, title: "Foo", decisions: [decision]},
             %{index: 1, title: "Bar", decisions: []}
           ] = by_section(review, v1)

    assert %{status: "approved", patchset_number: 1, carried_forward: false} = decision
    assert decision.author.id == agent.id
    assert %DateTime{} = decision.decided_at
  end

  test "an unchanged section carries its decision forward; a changed one loses it", ctx do
    %{review: review, v1: v1, agent: agent, user: user} = ctx
    decide(review, v1, agent, 0, "approved")
    decide(review, v1, agent, 1, "approved")

    {:ok, %{patchset: v2}} =
      ReviewsContext.append_patchset(review, agent, %{
        raw_diff: @diff_v2,
        packet: packet(["bar", "baz"])
      })

    assert [
             %{title: "Foo", decisions: [%{status: "approved", patchset_number: 1} = carried]},
             %{title: "Bar", decisions: []}
           ] = by_section(review, v2)

    assert carried.carried_forward

    # The owner's human identity decides the changed section again on v2. The
    # account has one decision per section, so the agent's v1 one is not listed.
    {:ok, human} = Accounts.ensure_human_identity(user)
    decide(review, v2, human, 1, "denied")

    assert [_, %{title: "Bar", decisions: [fresh]}] = by_section(review, v2)
    assert %{status: "denied", patchset_number: 2, carried_forward: false} = fresh
    assert fresh.author.kind == "human"

    # Reading v1 still shows what was decided there.
    assert [%{decisions: [%{carried_forward: false}]}, %{decisions: [%{status: "approved"}]}] =
             by_section(review, v1)
  end

  test "a section pinned back to pending reports pending, not the inherited decision", ctx do
    %{review: review, v1: v1, agent: agent} = ctx
    decide(review, v1, agent, 0, "approved")

    {:ok, %{patchset: v2}} =
      ReviewsContext.append_patchset(review, agent, %{raw_diff: @diff_v1, packet: packet(["bar"])})

    decide(review, v2, agent, 0, "pending")

    assert [%{decisions: [%{status: "pending", patchset_number: 2, carried_forward: false}]}, _] =
             by_section(review, v2)
  end
end
