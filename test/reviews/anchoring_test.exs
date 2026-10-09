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

  # --- Tier and option coverage ---------------------------------------------

  describe "relocate/4 exact tier" do
    test "a block moved far away is still found exactly, with its context" do
      filler = for i <- 1..100, do: "  # filler #{i}"
      v2 = insert_at(@cart, 1, filler)

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor_at(@cart, 11)),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2)
               )

      assert moved["line_number_hint"] == 111
      assert moved["relocation"]["score"] == 1.0
    end

    test "a distinctive line moved alone (no context agreement) is accepted" do
      line = "    Logger.info(\"cart total computed\")"
      v1 = insert_at(@cart, 10, [line])
      v2 = @cart |> insert_at(2, [line])

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor_at(v1, 11)),
                 added_file("lib/cart.ex", v1),
                 added_file("lib/cart.ex", v2)
               )

      assert moved["line_number_hint"] == 3
      assert moved["relocation"]["method"] == "exact"
    end

    test "a short line with no context agreement is not accepted" do
      v1 = ["a = 1", "b = 2", "  :ok", "c = 3"]
      v2 = ["x = 9", "  :ok", "y = 8"]

      assert {:error, :outdated} =
               Anchoring.relocate(
                 thread(anchor_at(v1, 3)),
                 added_file("lib/cart.ex", v1),
                 added_file("lib/cart.ex", v2)
               )
    end

    test "two distinctive copies with no context agreement are ambiguous" do
      line = "    Logger.info(\"cart total computed\")"
      v1 = insert_at(@cart, 10, [line])
      v2 = ["# one", line, "# two", "# three", line, "# four"]

      assert {:error, :ambiguous} =
               Anchoring.relocate(
                 thread(anchor_at(v1, 11)),
                 added_file("lib/cart.ex", v1),
                 added_file("lib/cart.ex", v2)
               )
    end

    test "re-indenting a line counts as unchanged" do
      v2 = List.replace_at(@cart, 10, "      price  *  qty")

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor_at(@cart, 11)),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2)
               )

      assert moved["relocation"]["method"] == "exact"
      assert moved["line_text"] == "      price  *  qty"
    end
  end

  describe "relocate/4 context tier" do
    test "a stricter :context_threshold rejects a partly changed neighbourhood" do
      v2 =
        @cart
        |> List.replace_at(10, "    price * item.qty")
        |> List.replace_at(8, "    price = item.unit_price")

      args = [
        thread(anchor_at(@cart, 11)),
        added_file("lib/cart.ex", @cart),
        added_file("lib/cart.ex", v2)
      ]

      assert {:ok, %{"relocation" => %{"method" => "context"}}} =
               apply(Anchoring, :relocate, args)

      assert {:error, :outdated} =
               apply(
                 Anchoring,
                 :relocate,
                 args ++ [[context_threshold: 1.0, fuzzy_threshold: 1.0]]
               )
    end

    test "a rewritten line in the same spot is outdated, not reattached" do
      v2 = List.replace_at(@cart, 10, "    Decimal.mult(item.price, item.qty)")

      assert {:error, :outdated} =
               Anchoring.relocate(
                 thread(anchor_at(@cart, 11)),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2)
               )
    end
  end

  describe "relocate/4 fuzzy tier" do
    setup do
      line = "    Logger.debug(\"computing line total for item\")"
      edited = "    Logger.debug(\"computing line totals for items\")"
      v1 = ["# a", "# b", "# c", line, "# d", "# e"]
      v2 = ["# one", "# two", "# three", "# four", edited, "# five"]
      %{v1: v1, v2: v2, edited: edited}
    end

    test "matches an edited line near the hint", %{v1: v1, v2: v2, edited: edited} do
      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor_at(v1, 4)),
                 added_file("lib/cart.ex", v1),
                 added_file("lib/cart.ex", v2)
               )

      assert moved["line_text"] == edited
      assert moved["relocation"]["method"] == "fuzzy"
      assert moved["relocation"]["score"] > 0.9
    end

    test ":fuzzy_threshold and :fuzzy_window tune the search", %{v1: v1, v2: v2} do
      args = [
        thread(anchor_at(v1, 4)),
        added_file("lib/cart.ex", v1),
        added_file("lib/cart.ex", v2)
      ]

      assert {:error, :outdated} = apply(Anchoring, :relocate, args ++ [[fuzzy_threshold: 0.99]])

      far = List.duplicate("# pad", 10) ++ v2

      args = [
        thread(anchor_at(v1, 4)),
        added_file("lib/cart.ex", v1),
        added_file("lib/cart.ex", far)
      ]

      assert {:error, :outdated} = apply(Anchoring, :relocate, args ++ [[fuzzy_window: 5]])
      assert {:ok, %{"line_number_hint" => 15}} = apply(Anchoring, :relocate, args)
    end

    test "two equally similar lines are ambiguous", %{v1: v1, edited: edited} do
      v2 = ["# one", edited, "# two", "# three", edited, "# four"]

      assert {:error, :ambiguous} =
               Anchoring.relocate(
                 thread(anchor_at(v1, 4, context: 0)),
                 added_file("lib/cart.ex", v1 |> Enum.map(fn _ -> "# x" end)),
                 added_file("lib/cart.ex", v2)
               )
    end
  end

  describe "relocate/4 inputs and options" do
    test ":context_size controls how much context is compared and stored" do
      v2 = insert_at(@cart, 1, ["  @moduledoc false"])

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor_at(@cart, 11)),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2),
                 context_size: 1
               )

      assert moved["context_before"] == ["    qty = item.qty"]
      assert moved["context_after"] == ["  end"]
    end

    test "accepts a %Thread{} struct" do
      v2 = insert_at(@cart, 1, ["  @moduledoc false"])

      thread = %Reviews.Threads.Thread{
        file_path: "lib/cart.ex",
        side: "new",
        anchor: anchor_at(@cart, 11)
      }

      assert {:ok, %{"line_number_hint" => 12}} =
               Anchoring.relocate(
                 thread,
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2)
               )
    end

    test "accepts string-keyed threads and string-keyed patchsets" do
      v2 = insert_at(@cart, 1, ["  @moduledoc false"])

      thread = %{"file_path" => "lib/cart.ex", "side" => "new", "anchor" => anchor_at(@cart, 11)}

      assert {:ok, %{"line_number_hint" => 12}} =
               Anchoring.relocate(
                 thread,
                 %{"raw_diff" => added_file_diff("lib/cart.ex", @cart)},
                 %{"raw_diff" => added_file_diff("lib/cart.ex", v2)}
               )
    end

    test "a bare anchor takes :file_path and :side from opts" do
      v2 = insert_at(@cart, 1, ["  @moduledoc false"])

      assert {:ok, %{"line_number_hint" => 12}} =
               Anchoring.relocate(
                 anchor_at(@cart, 11),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2),
                 file_path: "lib/cart.ex",
                 side: "new"
               )
    end

    test "missing line_text is read from the old patchset at the hint" do
      anchor = %{"granularity" => "line", "line_number_hint" => 11, "line_text" => ""}
      v2 = insert_at(@cart, 1, ["  @moduledoc false"])

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", v2)
               )

      assert moved["line_number_hint"] == 12
      assert moved["line_text"] == "    price * qty"
    end

    test "a stale hint does not supply context" do
      # The hint points at a different line than line_text, so the old
      # patchset's neighbours are not trusted. The short line then has no
      # context, so it is not matched at all.
      anchor = %{
        "granularity" => "line",
        "line_number_hint" => 2,
        "line_text" => "  end",
        "context_before" => [],
        "context_after" => []
      }

      assert {:error, :outdated} =
               Anchoring.relocate(
                 thread(anchor),
                 added_file("lib/cart.ex", @cart),
                 added_file("lib/cart.ex", @cart)
               )
    end

    test "follows a file renamed in an earlier patchset and renamed again" do
      v2 = insert_at(@cart, 1, ["  @moduledoc false"])

      assert {:ok, moved} =
               Anchoring.relocate(
                 thread(anchor_at(@cart, 11), "lib/basket.ex"),
                 rewrite("lib/cart.ex", "lib/basket.ex", @cart, @cart),
                 rewrite("lib/cart.ex", "lib/trolley.ex", @cart, v2)
               )

      assert moved["line_number_hint"] == 12
      assert moved["relocation"]["file_path"] == "lib/trolley.ex"
    end
  end

  describe "relocate/3 seeded random edits" do
    # Not StreamData (the repo has no such dep): a fixed seed makes this a
    # reproducible table of 200 random edit scripts.
    test "a distinct line always follows random inserts and deletes elsewhere" do
      :rand.seed(:exsss, {63, 62, 2026})

      for _round <- 1..200 do
        base = for i <- 1..40, do: "  value_#{i} = compute(#{i}, :seed)"
        target_index = :rand.uniform(40) - 1
        target = Enum.at(base, target_index)

        edited =
          Enum.reduce(1..:rand.uniform(12), base, fn step, lines ->
            target_at = Enum.find_index(lines, &(&1 == target))

            case :rand.uniform(2) do
              1 ->
                List.insert_at(lines, :rand.uniform(length(lines) + 1) - 1, "  extra_#{step}()")

              2 ->
                victim = :rand.uniform(length(lines)) - 1
                if victim == target_at, do: lines, else: List.delete_at(lines, victim)
            end
          end)

        expected = Enum.find_index(edited, &(&1 == target)) + 1

        assert {:ok, %{"line_number_hint" => ^expected}} =
                 Anchoring.relocate(
                   thread(anchor_at(base, target_index + 1)),
                   added_file("lib/cart.ex", base),
                   added_file("lib/cart.ex", edited)
                 )
      end
    end
  end
end

defmodule Reviews.Anchoring.DiffLinesTest do
  use ExUnit.Case, async: true

  alias Reviews.Anchoring.DiffLines

  @diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 1111111..2222222 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -1,3 +1,4 @@
   one
  -two
  +TWO
  +two and a half
   three
  @@ -10,2 +11,2 @@ def tail
   ten
  -eleven
  +ELEVEN
  \\ No newline at end of file
  """

  test "side_lines reads each side with real line numbers" do
    assert DiffLines.side_lines(@diff, "new") == %{
             1 => "one",
             2 => "TWO",
             3 => "two and a half",
             4 => "three",
             11 => "ten",
             12 => "ELEVEN"
           }

    assert DiffLines.side_lines(@diff, "old") == %{
             1 => "one",
             2 => "two",
             3 => "three",
             10 => "ten",
             11 => "eleven"
           }
  end

  test "side_lines ignores bad input" do
    assert DiffLines.side_lines(nil, "new") == %{}
    assert DiffLines.side_lines(@diff, "left") == %{}
  end

  test "neighbours stop at gaps between hunks" do
    lines = DiffLines.side_lines(@diff, "new")

    assert DiffLines.neighbours(lines, 11, -1, 3) == []
    assert DiffLines.neighbours(lines, 3, -1, 3) == ["one", "TWO"]
    assert DiffLines.neighbours(lines, 3, 1, 3) == ["three"]
  end

  test "find_file matches the new path, the pre-rename path, or an extra path" do
    diff = %{
      raw_diff:
        "diff --git a/lib/old.ex b/lib/new.ex\nrename from lib/old.ex\nrename to lib/new.ex\n"
    }

    assert %{path: "lib/new.ex"} = DiffLines.find_file(diff, "lib/new.ex")
    assert %{path: "lib/new.ex"} = DiffLines.find_file(diff, "lib/old.ex")
    assert %{path: "lib/new.ex"} = DiffLines.find_file(diff, "lib/mid.ex", ["lib/old.ex"])
    assert DiffLines.find_file(diff, "lib/other.ex") == nil
    assert DiffLines.find_file(%{}, "lib/new.ex") == nil
  end
end
