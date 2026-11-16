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
end
