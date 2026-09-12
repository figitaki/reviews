defmodule Reviews.DemoCatalogTest do
  use Reviews.DataCase, async: true

  test "seeds playable samples once and preserves discussions and revisions" do
    {:ok, author} =
      Reviews.Accounts.upsert_from_github(%{github_id: 91234, username: "demo-test"})

    samples = Reviews.DemoCatalog.seed!(author)
    assert length(samples) == 4
    assert Enum.map(Reviews.DemoCatalog.seed!(author), & &1.id) == Enum.map(samples, & &1.id)

    workflow = Enum.find(samples, &(&1.slug == "demo-workflow-v1"))
    assert length(Reviews.Reviews.list_patchsets(workflow)) == 2

    assert Enum.sort(Enum.map(Reviews.Threads.list_published_threads(workflow.id), & &1.status)) ==
             ["open", "resolved"]

    for sample <- samples do
      {:ok, snapshot} = Reviews.ReviewView.snapshot(sample, nil)
      assert snapshot.files != []
    end

    markdown = Enum.find(samples, &(&1.slug == "demo-markdown-v1"))
    files = markdown |> Reviews.Reviews.latest_patchset() |> Reviews.Reviews.list_files()
    assert Enum.sort(Enum.map(files, & &1.status)) == ["added", "deleted", "modified"]
  end
end
