defmodule Reviews.DemoReviewTest do
  use Reviews.DataCase, async: true

  alias Reviews.DemoReview
  alias Reviews.Repo
  alias Reviews.Reviews.Patchset

  test "reseeding keeps the demo review while its fixture is unchanged" do
    review = DemoReview.seed!()
    assert DemoReview.seed!().id == review.id
  end

  test "reseeding replaces the demo review when its fixture changed" do
    review = DemoReview.seed!()

    review
    |> Reviews.Reviews.latest_patchset()
    |> Patchset.changeset(%{raw_diff: "diff --git a/old b/old\n"})
    |> Repo.update!()

    replaced = DemoReview.seed!()
    assert replaced.id != review.id
    assert Reviews.Reviews.get_review_by_slug(DemoReview.slug()).id == replaced.id
  end
end
