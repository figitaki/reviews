defmodule Reviews.Repo.Migrations.AddDeviceAuthorization do
  @moduledoc """
  Gatekeep's storage version 2: device authorization requests (RFC 8628),
  for `reviews login`.
  """
  use Ecto.Migration

  def up, do: Gatekeep.Storage.Ecto.Migration.up(version: 2)
  def down, do: Gatekeep.Storage.Ecto.Migration.down(version: 2)
end
