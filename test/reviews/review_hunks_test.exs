defmodule Reviews.ReviewHunksTest do
  use ExUnit.Case, async: true

  alias Reviews.ReviewHunks
  alias Reviews.Reviews, as: ReviewsContext

  test "counts hunk rows that look like file headers as changed lines" do
    # Removing `-- note` and adding `++ x` give rows `--- note` and `+++ x`.
    raw_diff =
      "diff --git a/q.sql b/q.sql\n" <>
        "--- a/q.sql\n+++ b/q.sql\n" <>
        "@@ -1,2 +1,2 @@\n select 1;\n--- note\n+++ x\n"

    assert [%{path: "q.sql", additions: 1, deletions: 1} = file] =
             ReviewsContext.parse_diff_files(raw_diff)

    assert [%{additions: 1, deletions: 1}] = hunks = ReviewHunks.for_file(file)

    row = %{"path" => "q.sql", "hunk_index" => 1, "line_start" => 1, "line_end" => 2}

    assert %{display_additions: 0, display_deletions: 1} =
             ReviewHunks.for_packet_row(%{"q.sql" => hunks}, row)
  end

  test "empty hunk rows keep CLI slice numbering" do
    raw = File.read!(Path.expand("../vectors/diffs/empty-hunk-rows.diff", __DIR__))
    [file] = ReviewsContext.parse_diff_files(raw)
    hunks = ReviewHunks.for_file(file)
    row = %{"path" => "x.txt", "hunk_index" => 1, "line_start" => 3, "line_end" => 3}
    sliced = ReviewHunks.for_packet_row(%{"x.txt" => hunks}, row)
    assert sliced.display_raw_diff =~ "+new\n\\ No newline at end of file"
    refute sliced.display_raw_diff =~ "-old"
    assert sliced.display_additions == 1
    assert sliced.display_deletions == 0
  end

  test "rows preserve interior and final empty lines but not a newline terminator" do
    header = "diff --git a/x b/x\n--- a/x\n+++ b/x\n"

    for ending <- ["+last", "+last\n"] do
      [file] = ReviewsContext.parse_diff_files(header <> "@@ -1 +1 @@\n\n-old\n" <> ending)
      [hunk] = ReviewHunks.for_file(file)
      assert ReviewHunks.rows(hunk) == ["", "-old", "+last"]
    end

    raw = header <> "@@ -1 +1 @@\n-old\n+new\n\n@@ -3 +3 @@\n\n-end\n+end\n\n"
    [file] = ReviewsContext.parse_diff_files(raw)
    [first, second] = ReviewHunks.for_file(file)
    assert ReviewHunks.rows(first) == ["-old", "+new", ""]
    assert ReviewHunks.rows(second) == ["", "-end", "+end", ""]
    combined = ReviewHunks.combine_consecutive([first, second])
    assert combined.display_raw_diff =~ "+new\n\n@@ -3 +3 @@\n\n-end"
  end
end
