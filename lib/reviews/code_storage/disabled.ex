defmodule Reviews.CodeStorage.Disabled do
  @moduledoc """
  Default adapter: code storage is off. Every operation fails with
  `:code_storage_disabled` except deletes, which succeed so cleanup can never
  wedge on a disabled backend.
  """
  @behaviour Reviews.CodeStorage

  @impl true
  def create_repository(_repository), do: {:error, :code_storage_disabled}

  @impl true
  def upload_instructions(_repository, _snapshot), do: {:error, :code_storage_disabled}

  @impl true
  def verify(_repository, _snapshot), do: {:error, :code_storage_disabled}

  @impl true
  def delete_snapshot(_repository, _snapshot), do: :ok

  @impl true
  def delete_repository(_repository), do: :ok

  @impl true
  def checkout_source(_repository, _ref, _destination), do: {:error, :not_implemented}
end
