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

  test "packet slices retain source coordinates and canonical identity" do
    header = "diff --git a/x b/x\n--- a/x\n+++ b/x\n"

    for {hunk, first, last, expected} <- [
          {"@@ -27,7 +27,7 @@ function\n a\n b\n c\n-old\n+new\n d\n e\n f\n", 4, 5,
           "@@ -30,1 +30,1 @@ function"},
          {"@@ -10,4 +10,5 @@\n a\n-old\n+one\n+two\n b\n c\n", 5, 6, "@@ -12,2 +13,2 @@"},
          {"@@ -10,2 +10,3 @@\n a\n+new\n b\n", 2, 2, "@@ -10,0 +11,1 @@"},
          {"@@ -10,3 +10,2 @@\n a\n-old\n b\n", 2, 2, "@@ -11,1 +10,0 @@"},
          {"@@ -0,0 +1,2 @@\n+one\n+two\n", 2, 2, "@@ -0,0 +2,1 @@"}
        ] do
      [file] = ReviewsContext.parse_diff_files(header <> hunk)
      [canonical] = hunks = ReviewHunks.for_file(file)

      sliced =
        ReviewHunks.for_packet_row(%{"x" => hunks}, %{
          "path" => "x",
          "hunk_index" => 1,
          "line_start" => first,
          "line_end" => last
        })

      assert sliced.display_raw_diff =~ expected
      assert sliced.partial_line_range?
      assert sliced.hunk_fingerprint == canonical.hunk_fingerprint
      assert sliced.raw_diff == canonical.raw_diff
    end
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

  test "multi-file boundaries retain empty rows from the shared CLI vector" do
    raw = File.read!(Path.expand("../vectors/diffs/multi-file-empty-rows.diff", __DIR__))
    files = ReviewsContext.parse_diff_files(raw)
    assert Enum.map(files, & &1.path) == ["x.txt", "y.txt"]

    for file <- files do
      [hunk] = ReviewHunks.for_file(file)
      assert ReviewHunks.rows(hunk) == ["-old", "+new", ""]
    end
  end

  test "empty-only and trailing-empty slices round trip alone and combined" do
    raw =
      "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n\n-old\n+new\n\n@@ -3 +3 @@\n-end\n+end\n\n"

    [file] = ReviewsContext.parse_diff_files(raw)
    hunks = ReviewHunks.for_file(file)

    for {start, finish, expected} <- [{1, 1, [""]}, {2, 4, ["-old", "+new", ""]}] do
      slice =
        ReviewHunks.for_packet_row(%{"x" => hunks}, %{
          "path" => "x",
          "hunk_index" => 1,
          "line_start" => start,
          "line_end" => finish
        })

      [parsed] = ReviewHunks.for_file(%{file | raw_diff: slice.display_raw_diff})
      assert ReviewHunks.rows(parsed) == expected
      combined = ReviewHunks.combine_consecutive([slice, List.last(hunks)])
      assert [first, last] = ReviewHunks.for_file(%{file | raw_diff: combined.display_raw_diff})
      assert ReviewHunks.rows(first) == expected
      assert ReviewHunks.rows(last) == ["-end", "+end", ""]
    end

    for hunk <- hunks do
      [parsed] = ReviewHunks.for_file(%{file | raw_diff: hunk.raw_diff})
      assert ReviewHunks.rows(parsed) == ReviewHunks.rows(hunk)
    end
  end
end
