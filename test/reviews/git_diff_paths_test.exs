defmodule Reviews.GitDiffPathsTest do
  use ExUnit.Case, async: true

  alias Reviews.GitDiffPaths
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Reviews.Patchset

  test "decodes quoted and unquoted paths, including rename combinations" do
    assert GitDiffPaths.parse(~S|"a/caf\303\251.txt" "b/caf\303\251.txt"|) ==
             {:ok, "café.txt", "café.txt"}

    assert GitDiffPaths.parse(~S|a/old name "b/caf\303\251.txt"|) ==
             {:ok, "old name", "café.txt"}

    assert GitDiffPaths.parse(~S|"a/caf\303\251.txt" b/new name|) ==
             {:ok, "café.txt", "new name"}

    assert GitDiffPaths.parse(~S|"a/tab\t\"\\.txt" "b/tab\t\"\\.txt"|) ==
             {:ok, "tab\t\"\\.txt", "tab\t\"\\.txt"}
  end

  test "rejects malformed quoting and non-UTF-8 paths" do
    for header <- [
          ~S|"a/\400" b/file|,
          ~S|"a/\3" b/file|,
          ~S|"a/\q" b/file|,
          ~S|"a/unfinished b/file|,
          ~S|a/file "b/file" trailing|,
          ~S|"a/\377" b/file|,
          "invalid"
        ] do
      assert GitDiffPaths.parse(header) == :error
    end
  end

  test "binary additions and deletions retain decoded paths and exact lookup" do
    header = ~S|"a/caf\303\251.png" "b/caf\303\251.png"|

    for {mode, status} <- [{"new", "added"}, {"deleted", "deleted"}] do
      diff = "diff --git #{header}\n#{mode} file mode 100644\nBinary files differ\n"

      assert [%{path: "café.png", status: ^status, additions: 0, deletions: 0}] =
               ReviewsContext.parse_diff_files(diff)

      patchset = %Patchset{raw_diff: diff}
      assert ReviewsContext.raw_diff_for_file(patchset, "café.png") == diff
      assert ReviewsContext.raw_diff_for_file(patchset, "café") == nil
    end
  end
end
