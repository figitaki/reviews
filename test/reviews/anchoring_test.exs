defmodule Reviews.AnchoringTest do
  use ExUnit.Case, async: true

  alias Reviews.Anchoring

  @cart [
    "defmodule Cart do",
    "  def total(items) do",
    "    items",
    "    |> Enum.map(&line_total/1)",
    "    |> Enum.sum()",
    "  end",
    "",
    "  defp line_total(item) do",
    "    price = item.price",
    "    qty = item.qty",
    "    price * qty",
    "  end",
    "end"
  ]

  # --- Fixture helpers ------------------------------------------------------

  # A patchset whose diff adds `lines` as a brand-new file. Every line is on
  # the "new" side, numbered from 1.
  defp added_file(path, lines), do: %{raw_diff: added_file_diff(path, lines)}

  defp added_file_diff(path, lines) do
    """
    diff --git a/#{path} b/#{path}
    new file mode 100644
    index 0000000..1111111
    --- /dev/null
    +++ b/#{path}
    @@ -0,0 +1,#{length(lines)} @@
    """ <> Enum.map_join(lines, "", &"+#{&1}\n")
  end

  # A patchset that renames `old_path` to `new_path` and rewrites the whole
  # file: `old_lines` are on the "old" side, `new_lines` on the "new" side.
  defp rewrite(old_path, new_path, old_lines, new_lines) do
    rename =
      if old_path == new_path,
        do: "",
        else: "similarity index 90%\nrename from #{old_path}\nrename to #{new_path}\n"

    diff =
      "diff --git a/#{old_path} b/#{new_path}\n" <>
        rename <>
        "--- a/#{old_path}\n+++ b/#{new_path}\n" <>
        "@@ -1,#{length(old_lines)} +1,#{length(new_lines)} @@\n" <>
        Enum.map_join(old_lines, "", &"-#{&1}\n") <>
        Enum.map_join(new_lines, "", &"+#{&1}\n")

    %{raw_diff: diff}
  end

  # The anchor the client would build for 1-based line `n` of `lines`.
  defp anchor_at(lines, n, opts \\ []) do
    size = Keyword.get(opts, :context, 3)

    %{
      "granularity" => "line",
      "line_number_hint" => n,
      "line_text" => Enum.at(lines, n - 1),
      "context_before" => Enum.slice(lines, max(n - 1 - size, 0), min(size, n - 1)),
      "context_after" => Enum.slice(lines, n, size)
    }
  end

  defp thread(anchor, path \\ "lib/cart.ex", side \\ "new"),
    do: %{file_path: path, side: side, anchor: anchor}

  defp insert_at(lines, index, extra), do: List.insert_at(lines, index, extra) |> List.flatten()

  # --- Dispatch -------------------------------------------------------------

  describe "relocate/3 dispatch" do
    test "token_range granularity returns {:error, :not_implemented} (v1.5 stub)" do
      anchor = %{
        "granularity" => "token_range",
        "line_text" => "  const userId = req.user.id;",
        "context_before" => [],
        "context_after" => [],
        "token_offset_start" => 8,
        "token_offset_end" => 14,
        "token_text" => "userId"
      }

      thread = %{anchor: anchor}

      assert {:error, :not_implemented} = Anchoring.relocate(thread, %{}, %{})
    end

    test "unknown granularity returns {:error, :unknown_granularity}" do
      thread = %{anchor: %{"granularity" => "block"}}

      assert {:error, :unknown_granularity} = Anchoring.relocate(thread, %{}, %{})
    end

    test "accepts a plain anchor map (not wrapped in a thread struct)" do
      assert {:error, :not_implemented} =
               Anchoring.relocate(%{"granularity" => "token_range"}, %{}, %{})
    end

    test "a line anchor with no file content to search is outdated, not echoed back" do
      anchor = anchor_at(@cart, 11)

      assert {:error, :outdated} = Anchoring.relocate(thread(anchor), %{}, %{})
    end
  end

  # --- Failure modes from issue #63 -----------------------------------------

  describe "relocate/3 line anchors" do
    test "unchanged file keeps the same line" do
      ps = added_file("lib/cart.ex", @cart)
      anchor = anchor_at(@cart, 11)

      assert {:ok, moved} = Anchoring.relocate(thread(anchor), ps, ps)
      assert moved["line_number_hint"] == 11
      assert moved["line_text"] == "    price * qty"
      assert moved["relocation"]["method"] == "exact"
    end

    test "line shifted by insertions above follows its content" do
      v2 = insert_at(@cart, 1, ["  @moduledoc false", "", "  @tax 0.2"])

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor_at(@cart, 11)),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2)
               )

      assert moved["line_number_hint"] == 14
      assert Enum.at(v2, 13) == moved["line_text"]
      assert moved["relocation"]["method"] == "exact"
      assert moved["relocation"]["from_line"] == 11
    end

    test "hunk context changed but the line itself did not" do
      v2 =
        @cart
        |> List.replace_at(8, "    price = item.unit_price")
        |> List.replace_at(9, "    qty = item.quantity")
        |> insert_at(0, ["# cart.ex"])

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor_at(@cart, 11)),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2)
               )

      assert moved["line_number_hint"] == 12
      assert moved["relocation"]["method"] == "exact"
    end

    test "line edited slightly in place is matched by its surrounding context" do
      v2 = List.replace_at(@cart, 10, "    price * item.qty")

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor_at(@cart, 11)),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2)
               )

      assert moved["line_number_hint"] == 11
      assert moved["line_text"] == "    price * item.qty"
      assert moved["relocation"]["method"] == "context"
    end

    test "line edited slightly while its context also changed is matched fuzzily near its old spot" do
      v1 = insert_at(@cart, 10, ["    Logger.debug(\"computing line total for item\")"])
      v2 = List.replace_at(v1, 10, "    Logger.debug(\"computing line totals for items\")")

      v2 =
        v2 |> List.replace_at(8, "    p = item.price") |> List.replace_at(9, "    q = item.qty")

      v2 = v2 |> List.replace_at(11, "    p * q") |> insert_at(0, ["# header"])

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor_at(v1, 11)),
                 added_file("lib/cart.ex", v1),
                 added_file("lib/cart.ex", v2)
               )

      assert moved["line_number_hint"] == 12
      assert moved["line_text"] == "    Logger.debug(\"computing line totals for items\")"
      assert moved["relocation"]["method"] == "fuzzy"
    end

    test "file renamed: the anchor follows the file and reports the new path" do
      v2 = insert_at(@cart, 1, ["  @moduledoc false"])

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor_at(@cart, 11)),
                 added_file("lib/cart.ex", @cart),
                 rewrite("lib/cart.ex", "lib/basket.ex", @cart, v2)
               )

      assert moved["line_number_hint"] == 12
      assert moved["relocation"]["file_path"] == "lib/basket.ex"
    end

    test "duplicate identical lines are told apart by context" do
      # Line 12 is the second "  end" in the file.
      v2 = insert_at(@cart, 1, ["  @moduledoc false", ""])

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor_at(@cart, 12)),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2)
               )

      assert moved["line_number_hint"] == 14

      assert moved["context_before"] == [
               "    price = item.price",
               "    qty = item.qty",
               "    price * qty"
             ]
    end

    test "duplicate lines with empty client context use context from the old patchset" do
      # The JS client sends context_before/context_after as [] today.
      anchor = anchor_at(@cart, 12, context: 0)
      v2 = insert_at(@cart, 1, ["  @moduledoc false", ""])

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2)
               )

      assert moved["line_number_hint"] == 14
    end

    test "duplicate lines with identical context are reported as ambiguous" do
      block = ["  def a do", "    :ok", "  end"]
      v1 = ["defmodule Twins do"] ++ block ++ [""] ++ block ++ ["end"]
      # Drop the blank line between the twins so both copies have the same context.
      v2 = ["defmodule Twins do"] ++ block ++ block ++ ["end"]

      assert {:error, :ambiguous} =
               Anchoring.relocate(
                 thread(anchor_at(v1, 3, context: 1)),
                 added_file("lib/cart.ex", v1),
                 added_file("lib/cart.ex", v2)
               )
    end

    test "deleted line is outdated, not moved to a neighbour" do
      v2 = List.delete_at(@cart, 10)

      assert {:error, :outdated} =
               Anchoring.relocate(
                 thread(anchor_at(@cart, 11)),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2)
               )
    end

    test "deleted short line is outdated even if an identical line survives elsewhere" do
      # Remove `total/1` (lines 2-7). Its "  end" (line 6) is gone, but the
      # "  end" of line_total/1 survives with different context.
      v2 = Enum.take(@cart, 1) ++ Enum.drop(@cart, 7)

      assert {:error, :outdated} =
               Anchoring.relocate(
                 thread(anchor_at(@cart, 6)),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2)
               )
    end

    test "file missing from the new patchset is outdated" do
      assert {:error, :outdated} =
               Anchoring.relocate(
                 thread(anchor_at(@cart, 11)),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/other.ex", @cart)
               )
    end

    test "old-side anchors are searched on the old side of the new diff" do
      base = @cart
      v2_base = insert_at(base, 1, ["  @moduledoc false"])

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor_at(base, 9), "lib/cart.ex", "old"),
                 rewrite("lib/cart.ex", "lib/cart.ex", base, ["x"]),
                 rewrite("lib/cart.ex", "lib/cart.ex", v2_base, ["x"])
               )

      assert moved["line_number_hint"] == 10
      assert moved["line_text"] == "    price = item.price"
    end

    test "works on partial diffs with several hunks and gaps between them" do
      old_ps = %{
        raw_diff: """
        diff --git a/lib/cart.ex b/lib/cart.ex
        index 1111111..2222222 100644
        --- a/lib/cart.ex
        +++ b/lib/cart.ex
        @@ -8,5 +8,5 @@ defmodule Cart do
           defp line_total(item) do
             price = item.price
        -    qty = item.count
        +    qty = item.qty
             price * qty
           end
        """
      }

      new_ps = %{
        raw_diff: """
        diff --git a/lib/cart.ex b/lib/cart.ex
        index 1111111..3333333 100644
        --- a/lib/cart.ex
        +++ b/lib/cart.ex
        @@ -1,3 +1,5 @@
         defmodule Cart do
        +  @moduledoc false
        +
           def total(items) do
             items
        @@ -8,5 +10,5 @@ defmodule Cart do
           defp line_total(item) do
             price = item.price
        -    qty = item.count
        +    qty = item.qty
             price * qty
           end
        \\ No newline at end of file
        """
      }

      anchor = %{
        "granularity" => "line",
        "line_number_hint" => 11,
        "line_text" => "    price * qty",
        "context_before" => [],
        "context_after" => []
      }

      assert {:ok, moved} = Anchoring.relocate(thread(anchor), old_ps, new_ps)
      assert moved["line_number_hint"] == 13

      assert moved["context_before"] == [
               "  defp line_total(item) do",
               "    price = item.price",
               "    qty = item.qty"
             ]

      assert moved["context_after"] == ["  end"]
    end

    test "is deterministic" do
      v2 = insert_at(@cart, 1, ["  @moduledoc false"])

      args = [
        thread(anchor_at(@cart, 12)),
        added_file("lib/cart.ex", @cart),
        added_file("lib/cart.ex", v2)
      ]

      results = for _ <- 1..5, do: apply(Anchoring, :relocate, args)
      assert results |> Enum.uniq() |> length() == 1
    end
  end
end
