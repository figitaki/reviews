defmodule Reviews.AnalyticsFixtures do
  alias Reviews.Repo
  alias Reviews.Accounts.User
  alias Reviews.Reviews.{Review, Patchset, PacketSectionDecision}
  alias Reviews.Threads.{Thread, Comment}

  def credential do
    token = "rva_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    config = [
      token_sha256: Base.encode16(:crypto.hash(:sha256, token)),
      expires_at: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    ]

    {token, config}
  end

  def activity(opts \\ []) do
    %{rows: [[now]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT transaction_timestamp()", [])
    now = DateTime.truncate(now, :second)

    users =
      for number <- 1..3,
          do: insert(%User{}, %{github_id: 910_000 + number, username: "PRIVATE-user-#{number}"})

    [owner, _, _] = users

    [one, two, three] =
      Enum.map(users, fn user ->
        {:ok, identity} = Reviews.Accounts.ensure_human_identity(user)
        identity
      end)

    {:ok, agent_one} =
      Reviews.Accounts.create_agent_identity(owner, %{
        handle: "PRIVATE-agent-one",
        display_name: "PRIVATE-agent-one"
      })

    {:ok, agent_two} =
      Reviews.Accounts.create_agent_identity(owner, %{
        handle: "PRIVATE-agent-two",
        display_name: "PRIVATE-agent-two"
      })

    recent = DateTime.add(now, -86_400)
    review = review(one, recent, "recent")

    unless Keyword.get(opts, :single_owner, false) do
      review(two, DateTime.add(now, -7 * 86_400), "boundary")
      review(three, DateTime.add(now, -8 * 86_400), "older")
    end

    review(one, now, "future")

    patchset =
      insert(%Patchset{}, %{
        review_id: review.id,
        number: 1,
        raw_diff: "PRIVATE-DIFF",
        packet: %{"PRIVATE-PACKET" => true},
        inserted_at: recent,
        updated_at: recent
      })

    thread =
      insert(%Thread{}, %{
        review_id: review.id,
        originating_patchset_id: patchset.id,
        author_id: one.id,
        file_path: "PRIVATE-FILE",
        side: "new",
        anchor: %{},
        inserted_at: recent,
        updated_at: recent
      })

    insert(%Comment{}, %{
      thread_id: thread.id,
      author_id: agent_one.id,
      body: "PRIVATE-BODY",
      inserted_at: recent,
      updated_at: recent
    })

    insert(%PacketSectionDecision{}, %{
      review_id: review.id,
      patchset_id: patchset.id,
      author_id: agent_two.id,
      account_id: owner.id,
      section_index: 0,
      section_title: "PRIVATE-SECTION",
      section_fingerprint: "PRIVATE-FINGERPRINT",
      status: "approved",
      inserted_at: recent,
      updated_at: recent
    })

    %{user: owner}
  end

  defp review(user, at, slug),
    do:
      insert(%Review{}, %{
        author_id: user.id,
        slug: slug,
        title: "PRIVATE-TITLE",
        inserted_at: at,
        updated_at: at
      })

  defp insert(struct, attrs), do: struct |> Ecto.Changeset.change(attrs) |> Repo.insert!()
end
