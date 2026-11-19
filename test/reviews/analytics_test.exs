defmodule Reviews.AnalyticsTest do
  use Reviews.DataCase, async: true
  import Reviews.AnalyticsFixtures

  test "only fixed aggregates leave the database, with owners deduplicated across human and two agent identities" do
    activity()
    assert {:ok, snapshot} = Reviews.Analytics.snapshot()

    assert Map.keys(snapshot) |> Enum.sort() ==
             ~w(accounts collected_at mcp_clients source version windows)

    assert snapshot["version"] == 2
    assert snapshot["source"] == "reviews aggregate endpoint v2"
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
             ~w(active_accounts comments days decisions end mcp_active_accounts mcp_connections
                reviews revisions signups start)

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
        key <- ~w(active_accounts reviews revisions comments decisions signups mcp_connections
                  mcp_active_accounts) do
      assert row[key] == 0
    end

    assert snapshot["accounts"] == 0

    assert snapshot["mcp_clients"] == [
             %{"app" => "Claude", "connected_accounts" => 0, "connections" => 0},
             %{"app" => "ChatGPT", "connected_accounts" => 0, "connections" => 0},
             %{"app" => "Amp", "connected_accounts" => 0, "connections" => 0},
             %{"app" => "Unrecognized", "connected_accounts" => 0, "connections" => 0}
           ]
  end

  test "signups and MCP connections by app, without client IDs or other resources" do
    mcp_connections()
    assert {:ok, snapshot} = Reviews.Analytics.snapshot()
    assert snapshot["accounts"] == 3

    # Revoked and expired grants are not connected; the Poppy grant is not MCP at all.
    assert snapshot["mcp_clients"] == [
             %{"app" => "Claude", "connected_accounts" => 1, "connections" => 2},
             %{"app" => "ChatGPT", "connected_accounts" => 1, "connections" => 1},
             %{"app" => "Amp", "connected_accounts" => 0, "connections" => 0},
             %{"app" => "Unrecognized", "connected_accounts" => 1, "connections" => 1}
           ]

    assert [week, month] = snapshot["windows"]
    assert {week["signups"], month["signups"]} == {1, 2}
    assert {week["mcp_connections"], month["mcp_connections"]} == {2, 4}
    assert {week["mcp_active_accounts"], month["mcp_active_accounts"]} == {1, 3}
    # MCP use alone does not make an account active; that counts authored activity.
    assert {week["active_accounts"], month["active_accounts"]} == {0, 0}
    refute JSON.encode!(snapshot) =~ "PRIVATE"
  end
end
