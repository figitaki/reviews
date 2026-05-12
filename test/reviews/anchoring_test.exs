defmodule Reviews.AnchoringTest do
  use ExUnit.Case, async: true

  alias Reviews.Anchoring

  describe "relocate/3" do
    test "line granularity returns {:ok, anchor} (placeholder)" do
      anchor = %{
        "granularity" => "line",
        "line_text" => "  const userId = req.user.id;",
        "context_before" => ["function getUser(req) {"],
        "context_after" => ["  return db.users.findOne({ id: userId });"],
        "line_number_hint" => 42
      }

      thread = %{anchor: anchor}

      assert {:ok, ^anchor} = Anchoring.relocate(thread, %{}, %{})
    end

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
  end
end
