defmodule Reviews.AnchoringTest do
  use ExUnit.Case, async: true
  alias Reviews.Anchoring

  defp patch(body, start \\ 1, path \\ "foo") do
    %{
      raw_diff:
        "diff --git a/#{path} b/#{path}\n--- a/#{path}\n+++ b/#{path}\n@@ -#{start},3 +#{start},3 @@\n#{body}\n"
    }
  end

  defp thread(extra \\ %{}) do
    %{
      file_path: "foo",
      side: "new",
      anchor:
        Map.merge(
          %{
            "granularity" => "line",
            "line_text" => "target",
            "line_number_hint" => 1,
            "context_before" => [],
            "context_after" => []
          },
          extra
        )
    }
  end

  test "relocates by exact text, never by the old line hint" do
    assert {:ok, anchor} =
             Anchoring.relocate(thread(), patch("+target"), patch("+inserted\n+target", 40))

    assert anchor["line_number_hint"] == 41
  end

  test "duplicates are outdated even if one is at the old position" do
    assert {:error, :outdated} =
             Anchoring.relocate(thread(), patch("+target"), patch("+target\n+target"))
  end

  test "a deleted repeated line never jumps to the surviving copy" do
    original = patch("+first block\n+target\n+first end\n+second block\n+target\n+second end")
    t = thread(%{"line_number_hint" => 2})

    assert {:error, :outdated} =
             Anchoring.relocate(t, original, patch("+second block\n+target\n+second end"))
  end

  test "exact context disambiguates duplicate lines" do
    t = thread(%{"context_before" => ["before"], "context_after" => ["after"]})

    assert {:ok, anchor} =
             Anchoring.relocate(t, patch("+target"), patch("+target\n+before\n+target\n+after"))

    assert anchor["line_number_hint"] == 3
  end

  test "vanished, changed, opposite-side, and other-file text cannot match" do
    for target <- [
          patch("+replacement"),
          patch("-target\n+replacement"),
          patch("+target", 1, "other"),
          patch("+replacement", 99)
        ] do
      assert {:error, :outdated} = Anchoring.relocate(thread(), patch("+target"), target)
    end
  end

  test "old-side deletion and context coordinates count only old-side lines" do
    t = %{thread() | side: "old"}

    assert {:ok, anchor} =
             Anchoring.relocate(t, patch("-target"), patch("+insertion\n context\n-target", 10))

    assert anchor["line_number_hint"] == 11
  end

  test "missing line text can be recovered only from known source lines" do
    t = thread() |> update_in([:anchor], &Map.delete(&1, "line_text"))
    assert {:ok, _} = Anchoring.relocate(t, patch("+target"), patch("+target", 8))
    assert {:error, :outdated} = Anchoring.relocate(t, patch("+target", 50), patch("+target", 8))
  end

  test "token ranges preserve selected text and UTF-16 offsets on moved lines" do
    t =
      thread(%{
        "granularity" => "token_range",
        "line_text" => "😀 target",
        "selection_text" => "target",
        "selection_offset" => 3
      })

    assert {:ok, anchor} = Anchoring.relocate(t, patch("+😀 target"), patch("+😀 target", 30))
    assert anchor["line_number_hint"] == 30
    assert anchor["selection_offset"] == 3
    assert anchor["selection_text"] == "target"
    bad = put_in(t, [:anchor, "selection_text"], "missing")

    assert {:error, :outdated} =
             Anchoring.relocate(bad, patch("+😀 target"), patch("+😀 target", 30))
  end

  test "legacy tokens without offsets require unique selected text" do
    t = thread(%{"granularity" => "token_range", "selection_text" => "target"})
    assert {:ok, _} = Anchoring.relocate(t, patch("+target"), patch("+target", 4))
    repeated = put_in(t, [:anchor, "line_text"], "target target")
    assert {:error, :outdated} = Anchoring.relocate(repeated, %{}, patch("+target target"))
  end

  test "unknown granularity retains the dispatch error" do
    assert {:error, :unknown_granularity} =
             Anchoring.relocate(thread(%{"granularity" => "block"}), %{}, %{})
  end
end
