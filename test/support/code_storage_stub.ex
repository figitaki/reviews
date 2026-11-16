defmodule Reviews.CodeStorage.Stub do
  @moduledoc """
  Programmable code-storage adapter for tests.

  Defaults to succeeding with deterministic values. Override a callback's
  result per test via:

      Application.put_env(:reviews, Reviews.CodeStorage.Stub,
        verify: {:error, :ref_mismatch}
      )

  Tests that select this adapter (or override its responses) mutate global
  application env and must be `async: false`.
  """
  @behaviour Reviews.CodeStorage

  @impl true
  def create_repository(repository) do
    respond(
      :create_repository,
      {:ok, %{storage_key: repository.storage_key, provider_repo_id: "stub-repo-id"}}
    )
  end

  @impl true
  def upload_instructions(_repository, _snapshot) do
    respond(
      :upload_instructions,
      {:ok,
       %{
         remote_url: "http://stub.invalid/reviews/stub.git",
         token: "stub-token",
         expires_at: DateTime.add(DateTime.utc_now(), 900)
       }}
    )
  end

  @impl true
  def verify(_repository, snapshot) do
    respond(:verify, {:ok, %{base_oid: snapshot.base_oid, head_oid: snapshot.head_oid}})
  end

  @impl true
  def delete_snapshot(_repository, _snapshot), do: respond(:delete_snapshot, :ok)

  @impl true
  def delete_repository(_repository), do: respond(:delete_repository, :ok)

  @impl true
  def checkout_source(_repository, _ref, _destination), do: {:error, :not_implemented}

  defp respond(callback, default) do
    Application.get_env(:reviews, __MODULE__, [])
    |> Keyword.get(callback, default)
  end
end
