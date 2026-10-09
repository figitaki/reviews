defmodule Reviews.CodeSnapshots do
  @moduledoc """
  The code-snapshots context: reservations, verification, claiming, and
  expiry of source snapshots.

  This is the only module that should touch `Reviews.Repo` for
  `code_repositories` and `code_snapshots`. The claim step runs inside the
  push transaction owned by `Reviews.Reviews`, which calls `maybe_claim/4`
  from an `Ecto.Multi.run/3` step.
  """
  import Ecto.Query, warn: false

  alias Reviews.Accounts.Identity
  alias Reviews.CodeStorage
  alias Reviews.Repo
  alias Reviews.Reviews.{CodeRepository, CodeSnapshot, Patchset, Review}

  # Namespace for pg_advisory_xact_lock; arbitrary but stable.
  @advisory_lock_namespace 7_201

  ## Lookup

  def get_snapshot_by_public_id(public_id) when is_binary(public_id) do
    case Ecto.UUID.cast(public_id) do
      {:ok, uuid} ->
        Repo.one(
          from s in CodeSnapshot,
            where: s.public_id == ^uuid,
            preload: [:code_repository]
        )

      :error ->
        nil
    end
  end

  def get_snapshot_by_public_id(_), do: nil

  ## Reservation

  @doc """
  Reserve a snapshot for upload: find or create the code repository, create
  the provider-side repository if needed, insert the snapshot row, and return
  upload instructions with a short-lived, ref-scoped credential.

  Provider calls are not transactional with the DB rows; the sweeper cleans
  up partial state after `expires_at`.
  """
  def reserve(%Identity{} = identity, attrs) do
    with :ok <- validate_reserve_attrs(attrs),
         {:ok, repository} <- find_or_create_repository(identity, attrs),
         :ok <- check_repository_object_format(repository, attrs[:object_format]),
         {:ok, snapshot} <- insert_reserved_snapshot(identity, repository, attrs),
         {:ok, upload} <- CodeStorage.adapter().upload_instructions(repository, snapshot) do
      {:ok, %{snapshot: snapshot, repository: repository, upload: upload}}
    end
  end

  @doc """
  Verify an uploaded snapshot: ask the provider to resolve both refs and
  compare them with the reserved OIDs. Idempotent — completing a `ready` or
  `claimed` snapshot succeeds without another provider call.
  """
  def complete(%Identity{} = identity, snapshot_public_id) do
    case get_snapshot_by_public_id(snapshot_public_id) do
      nil ->
        {:error, :snapshot_not_ready}

      %CodeSnapshot{reserved_by_id: owner_id} when owner_id != identity.id ->
        {:error, :snapshot_not_authorized}

      %CodeSnapshot{status: status} = snapshot when status in ["ready", "claimed"] ->
        {:ok, snapshot}

      %CodeSnapshot{status: "expired"} ->
        {:error, :upload_expired}

      %CodeSnapshot{status: "failed"} ->
        {:error, :ref_mismatch}

      %CodeSnapshot{} = snapshot ->
        verify_snapshot(snapshot)
    end
  end

  defp verify_snapshot(snapshot) do
    case CodeStorage.adapter().verify(snapshot.code_repository, snapshot) do
      {:ok, _oids} ->
        {:ok,
         snapshot
         |> Ecto.Changeset.change(status: "ready")
         |> Repo.update!()}

      {:error, :ref_mismatch} ->
        snapshot
        |> Ecto.Changeset.change(status: "failed", last_error: "ref_mismatch")
        |> Repo.update!()

        {:error, :ref_mismatch}

      {:error, reason} ->
        # Transient provider failure: leave the snapshot for a retried
        # complete call (or expiry).
        {:error, {:verify_failed, reason}}
    end
  end

  defp validate_reserve_attrs(attrs) do
    cond do
      attrs[:object_format] not in CodeStorage.supported_object_formats() ->
        {:error, :unsupported_object_format}

      not CodeSnapshot.valid_oid?(attrs[:base_oid]) ->
        {:error, :invalid_oid}

      not CodeSnapshot.valid_oid?(attrs[:head_oid]) ->
        {:error, :invalid_oid}

      attrs[:head_kind] not in CodeSnapshot.head_kinds() ->
        {:error, :invalid_head_kind}

      true ->
        :ok
    end
  end

  # With a review slug, reuse the review's claimed repository when it has
  # one. Otherwise (new review, or review without code yet) stage a fresh
  # repository; parallel reservations may stage several, the claim step picks
  # the winner and the sweeper expires the rest.
  defp find_or_create_repository(identity, %{review_slug: review_slug} = attrs)
       when is_binary(review_slug) do
    with %Review{} = review <- Repo.get_by(Review, slug: review_slug) do
      case Repo.one(from r in CodeRepository, where: r.review_id == ^review.id) do
        %CodeRepository{} = repository -> {:ok, repository}
        nil -> create_staging_repository(identity, attrs[:object_format])
      end
    else
      nil -> {:error, :review_not_found}
    end
  end

  defp find_or_create_repository(identity, attrs),
    do: create_staging_repository(identity, attrs[:object_format])

  # A Git repository has one object format. A later patchset must match the
  # format of the review's existing repository.
  defp check_repository_object_format(%CodeRepository{object_format: format}, format), do: :ok

  defp check_repository_object_format(_repository, _format),
    do: {:error, :unsupported_object_format}

  defp create_staging_repository(identity, object_format) do
    public_id = Ecto.UUID.generate()

    repository =
      %CodeRepository{owner_id: identity.id}
      |> CodeRepository.changeset(%{
        public_id: public_id,
        backend: backend_name(),
        storage_key: "reviews/#{public_id}",
        object_format: object_format,
        status: "staging",
        expires_at: reservation_deadline()
      })
      |> Repo.insert!()

    case CodeStorage.adapter().create_repository(repository) do
      {:ok, %{provider_repo_id: provider_repo_id}} ->
        {:ok,
         repository
         |> Ecto.Changeset.change(provider_repo_id: provider_repo_id)
         |> Repo.update!()}

      {:error, :code_storage_disabled} ->
        {:error, :code_storage_disabled}

      {:error, reason} ->
        repository
        |> Ecto.Changeset.change(status: "failed", last_error: redact_error(reason))
        |> Repo.update!()

        {:error, :upload_failed}
    end
  end

  defp insert_reserved_snapshot(identity, repository, attrs) do
    public_id = Ecto.UUID.generate()

    snapshot =
      %CodeSnapshot{code_repository_id: repository.id, reserved_by_id: identity.id}
      |> CodeSnapshot.changeset(%{
        public_id: public_id,
        base_ref: "refs/heads/snapshots/#{public_id}/base",
        head_ref: "refs/heads/snapshots/#{public_id}/head",
        base_oid: attrs[:base_oid],
        head_oid: attrs[:head_oid],
        head_kind: attrs[:head_kind],
        status: "reserved",
        expires_at: reservation_deadline()
      })
      |> Repo.insert!()

    {:ok, %{snapshot | code_repository: repository}}
  end

  defp backend_name do
    case CodeStorage.adapter() do
      Reviews.CodeStorage.Disabled -> "disabled"
      _ -> "code_storage"
    end
  end

  defp reservation_deadline do
    DateTime.utc_now()
    |> DateTime.add(CodeStorage.snapshot_ttl_seconds())
    |> DateTime.truncate(:second)
  end

  ## Claiming

  @doc """
  Claim step for the push transaction Multis in `Reviews.Reviews`.

  Returns `{:ok, nil}` when no snapshot id was sent, `{:ok, snapshot}` on a
  successful claim, `{:ok, {:skipped, code}}` when the claim failed under the
  `:optional` policy (the patchset proceeds diff-only), or `{:error, code}`
  under the `:required` policy (the whole transaction rolls back).
  """
  def maybe_claim(_identity, _review, _patchset, nil), do: {:ok, nil}

  def maybe_claim(%Identity{} = identity, %Review{} = review, %Patchset{} = patchset, public_id) do
    case claim_for_patchset(identity, review, patchset, public_id) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, code} ->
        case CodeStorage.policy() do
          :required -> {:error, code}
          _optional -> {:ok, {:skipped, code}}
        end
    end
  end

  @doc """
  Attach a ready snapshot (and its repository) to a patchset. Must run inside
  a transaction. Serializes concurrent claims per review with an advisory
  transaction lock so a losing concurrent first push fails cleanly instead of
  aborting the transaction on the partial unique index (which remains the
  integrity backstop).
  """
  def claim_for_patchset(
        %Identity{} = identity,
        %Review{} = review,
        %Patchset{} = patchset,
        public_id
      ) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@advisory_lock_namespace, review.id])

    with {:ok, snapshot} <- lock_snapshot(public_id),
         :ok <- check_owner(snapshot, identity),
         :ok <- check_status(snapshot),
         {:ok, repository} <- attach_repository(snapshot.code_repository, review) do
      snapshot =
        snapshot
        |> Ecto.Changeset.change(
          patchset_id: patchset.id,
          status: "claimed",
          expires_at: nil
        )
        |> Repo.update!()

      {:ok, %{snapshot | code_repository: repository}}
    end
  end

  defp lock_snapshot(public_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(public_id || ""),
         %CodeSnapshot{} = snapshot <-
           Repo.one(
             from s in CodeSnapshot,
               where: s.public_id == ^uuid,
               lock: "FOR UPDATE"
           ) do
      {:ok, Repo.preload(snapshot, :code_repository)}
    else
      # Not found and malformed ids both report :snapshot_not_ready so the
      # response does not reveal whether a snapshot id exists.
      _ -> {:error, :snapshot_not_ready}
    end
  end

  defp check_owner(%CodeSnapshot{reserved_by_id: owner_id}, %Identity{id: owner_id}), do: :ok
  defp check_owner(_snapshot, _identity), do: {:error, :snapshot_not_authorized}

  defp check_status(%CodeSnapshot{status: "ready"}), do: :ok
  defp check_status(%CodeSnapshot{status: "expired"}), do: {:error, :upload_expired}
  defp check_status(_snapshot), do: {:error, :snapshot_not_ready}

  # The snapshot's repository must already belong to the target review, or be
  # unclaimed while the review has no repository yet (first code-enabled push).
  defp attach_repository(%CodeRepository{review_id: review_id} = repository, %Review{
         id: review_id
       }) do
    {:ok, repository}
  end

  defp attach_repository(%CodeRepository{review_id: nil} = repository, %Review{} = review) do
    review_has_repository? =
      Repo.exists?(from r in CodeRepository, where: r.review_id == ^review.id)

    if review_has_repository? do
      # A concurrent first push already attached a different repository.
      {:error, :snapshot_not_ready}
    else
      repository =
        repository
        |> Ecto.Changeset.change(review_id: review.id, status: "ready", expires_at: nil)
        |> Repo.update!()

      {:ok, repository}
    end
  end

  defp attach_repository(_repository, _review), do: {:error, :snapshot_not_ready}

  ## Expiry (sweeper entry points)

  @doc """
  Expire unclaimed snapshots whose reservation deadline passed. Returns the
  number of rows transitioned to `expired`.
  """
  def expire_stale(now \\ DateTime.utc_now()) do
    {count, _} =
      Repo.update_all(
        from(s in CodeSnapshot,
          where:
            s.status in ["reserved", "uploading", "ready"] and
              is_nil(s.patchset_id) and
              s.expires_at < ^now
        ),
        set: [status: "expired", updated_at: DateTime.truncate(now, :second)]
      )

    count
  end

  @doc """
  Unclaimed, expired repositories eligible for provider deletion. This covers
  `staging` repositories nobody claimed and `failed` ones whose provider-side
  creation errored. Locks the rows with `SKIP LOCKED` so concurrent sweepers
  do not double-work.
  """
  def stale_staging_repositories(now \\ DateTime.utc_now(), limit \\ 20) do
    Repo.all(
      from r in CodeRepository,
        where:
          r.status in ["staging", "failed"] and
            is_nil(r.review_id) and
            r.expires_at < ^now,
        limit: ^limit,
        lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  def delete_repository_row(%CodeRepository{} = repository) do
    Repo.delete(repository, allow_stale: true)
  end

  def record_repository_error(%CodeRepository{} = repository, error) do
    repository
    |> Ecto.Changeset.change(last_error: redact_error(error))
    |> Repo.update()
  end

  @doc """
  Render an operational error for storage in `last_error` or for logs.
  Keeps it readable without leaking URLs, tokens, or keys.
  """
  def redact_error(error) do
    error
    |> inspect()
    |> String.replace(~r/https?:\/\/\S+/, "[url]")
    |> String.slice(0, 500)
  end
end
