defmodule Reviews.AnalyticsTest do
  use Reviews.DataCase, async: true
  import Reviews.AnalyticsFixtures

  test "only fixed aggregates leave the database, with owners deduplicated across human and two agent identities" do
    activity()
    assert {:ok, snapshot} = Reviews.Analytics.snapshot()
    assert Map.keys(snapshot) |> Enum.sort() == ~w(collected_at source version windows)
    assert snapshot["source"] == "reviews aggregate endpoint v1"
    assert [week, month] = snapshot["windows"]
    assert week["days"] == 7
    assert month["days"] == 30
    assert week["reviews"] == 2
    assert month["reviews"] == 3
    assert week["active_accounts"] == 2
    assert month["active_accounts"] == 3
    assert week["comments"] == 1
    assert week["decisions"] == 1
    assert week["revisions"] == 1

    assert Map.keys(week) |> Enum.sort() ==
             ~w(active_accounts comments days decisions end reviews revisions start)

    refute JSON.encode!(snapshot) =~ "PRIVATE"

    for window <- snapshot["windows"] do
      {:ok, finish, 0} = DateTime.from_iso8601(window["end"])
      {:ok, start, 0} = DateTime.from_iso8601(window["start"])
      assert DateTime.diff(finish, start) == window["days"] * 86_400
    end
  end

  test "one human and two agent identities owned by one account count once" do
    activity(single_owner: true)
    assert {:ok, snapshot} = Reviews.Analytics.snapshot()

    for window <- snapshot["windows"] do
      assert window["active_accounts"] == 1
      assert window["reviews"] == 1
      assert window["comments"] == 1
      assert window["decisions"] == 1
    end
  end

  test "empty data is explicit zero, not fabricated missing data" do
    assert {:ok, snapshot} = Reviews.Analytics.snapshot()

    for row <- snapshot["windows"],
        key <- ~w(active_accounts reviews revisions comments decisions) do
      assert row[key] == 0
    end
  end
end
