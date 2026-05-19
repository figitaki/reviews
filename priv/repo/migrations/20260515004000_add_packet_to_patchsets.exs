defmodule Reviews.Repo.Migrations.AddPacketToPatchsets do
  use Ecto.Migration

  def change do
    alter table(:patchsets) do
      add :packet, :map
    end
  end
end
