defmodule Reviews.AbuseFixtures do
  @moduledoc false
  alias Reviews.Accounts

  def token_fixture do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.upsert_from_github(%{github_id: 5_000_000 + unique, username: "budget-#{unique}"})

    {:ok, token, raw} = Accounts.mint_token(user, %{"name" => "budget"})
    %{user: user, token: token, raw: raw}
  end

  def observe_token_query(_event, _measurements, metadata, observer) do
    if self() == observer and metadata.source == "api_tokens" and
         String.starts_with?(metadata.query, "SELECT") do
      send(observer, :token_lookup)
    end
  end

  def review_body do
    JSON.encode!(%{
      title: "Budget regression",
      raw_diff: "diff --git a/foo b/foo\n--- a/foo\n+++ b/foo\n@@ -1 +1 @@\n-old\n+new\n",
      packet: %{
        format_version: 1,
        title: "Packet",
        summary: String.duplicate("x", 70_000),
        sections: [
          %{title: "Change", rows: [%{kind: "hunk", path: "foo", hunk_index: 1}]}
        ]
      }
    })
  end
end
