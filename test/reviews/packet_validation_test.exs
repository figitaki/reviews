defmodule Reviews.PacketValidationTest do
  use Reviews.DataCase, async: true
  alias Reviews.{Accounts, PacketValidation, Repo}
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.{Review, Patchset}

  @diff "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n"
  defp packet(rows \\ [%{"kind" => "hunk", "path" => "x", "hunk_index" => 1}]) do
    %{"title" => "T", "sections" => [%{"title" => "S", "rows" => rows}]}
  end

  defp codes(value) do
    {:error, problems} = PacketValidation.check(value, @diff)
    Enum.map(problems, & &1.code)
  end

  test "nil packets remain optional, valid packets cover every change" do
    assert :ok = PacketValidation.check(nil, @diff)
    assert :ok = PacketValidation.check(packet(), @diff)
  end

  test "strict shapes and integers reject malformed user input" do
    for bad <- [
          false,
          [],
          1,
          "packet",
          %{},
          %{"title" => " ", "sections" => []},
          %{"title" => "T", "sections" => [nil]}
        ] do
      assert "invalid_packet.shape" in codes(bad)
    end

    for row <- [
          %{"kind" => "hunk", "path" => " ", "hunk_index" => 1},
          %{"kind" => "hunk", "path" => "x", "hunk_index" => "1"},
          %{"kind" => "markdown", "body" => 1},
          nil
        ] do
      assert "invalid_packet.shape" in codes(packet([row]))
    end
  end

  test "missing, repeated, unknown and invalid slices are distinct problems" do
    assert "invalid_packet.uncovered_line" in codes(packet([]))
    row = %{"kind" => "hunk", "path" => "x", "hunk_index" => 1}
    assert "invalid_packet.repeated_line" in codes(packet([row, row]))
    assert "invalid_packet.unknown_hunk" in codes(packet([Map.put(row, "path", "other")]))

    for slice <- [
          %{"line_start" => 1},
          %{"line_start" => "1", "line_end" => 2},
          %{"line_start" => 0, "line_end" => 2},
          %{"line_start" => 1, "line_end" => 3},
          %{"line_start" => nil, "line_end" => nil}
        ] do
      assert "invalid_packet.invalid_slice" in codes(packet([Map.merge(row, slice)]))
    end
  end

  test "repeated context slices do not traverse their combined row lengths" do
    raw =
      "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n" <>
        String.duplicate(" context\n", 10_000) <> "-old\n+new\n"

    context = %{
      "kind" => "hunk",
      "path" => "x",
      "hunk_index" => 1,
      "line_start" => 1,
      "line_end" => 10_000
    }

    changed = %{context | "line_start" => 10_001, "line_end" => 10_002}
    value = packet(List.duplicate(context, 1_000) ++ [changed])
    {:reductions, before} = Process.info(self(), :reductions)
    assert :ok = PacketValidation.check(value, raw)
    {:reductions, after_count} = Process.info(self(), :reductions)
    # A generous deterministic work budget, not a wall-clock timing assertion.
    assert after_count - before < 5_000_000

    assert {:error, [%{code: "invalid_packet.repeated_line", detail: detail}]} =
             PacketValidation.check(packet([changed, %{changed | "line_end" => 10_001}]), raw)

    assert detail =~ "x#1:L10001 is covered 2 times"
  end

  test "invalid packets cannot persist a review or appended revision" do
    {:ok, user} =
      Accounts.upsert_from_github(%{
        github_id: System.unique_integer([:positive]),
        username: "packet-author"
      })

    before_count = Repo.aggregate(Review, :count)

    assert {:error, :patchset, changeset, _} =
             ReviewsContext.create_review_with_initial_patchset(user, %{
               title: "T",
               raw_diff: @diff,
               packet: packet([])
             })

    assert changeset.errors[:packet]
    assert Repo.aggregate(Review, :count) == before_count

    {:ok, %{review: review}} =
      ReviewsContext.create_review_with_initial_patchset(user, %{
        title: "T",
        raw_diff: @diff,
        packet: packet()
      })

    assert {:error, changeset} =
             ReviewsContext.append_patchset_unchecked(review, %{
               raw_diff: @diff,
               packet: packet([])
             })

    assert changeset.errors[:packet]
    assert Repo.aggregate(Patchset, :count) == 1
  end
end
