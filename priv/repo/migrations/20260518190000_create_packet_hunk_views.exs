defmodule Reviews.Repo.Migrations.CreatePacketHunkViews do
  use Ecto.Migration

  def change do
    create table(:packet_hunk_views) do
      add :review_id, references(:reviews, on_delete: :delete_all), null: false
      add :patchset_id, references(:patchsets, on_delete: :delete_all), null: false
      add :author_id, references(:users, on_delete: :delete_all), null: false
      add :file_path, :text, null: false
      add :row_ref, :text, null: false
      add :hunk_fingerprint, :string, null: false
      add :hunk_index, :integer, null: false
      add :line_start, :integer
      add :line_end, :integer
      add :section_index, :integer
      add :section_title, :text

      timestamps(type: :utc_datetime)
    end

    create index(:packet_hunk_views, [:review_id])
    create index(:packet_hunk_views, [:patchset_id])
    create index(:packet_hunk_views, [:author_id])
    create index(:packet_hunk_views, [:review_id, :author_id, :file_path])

    create unique_index(
             :packet_hunk_views,
             [:review_id, :author_id, :file_path, :row_ref, :hunk_fingerprint],
             name: :packet_hunk_views_one_per_user_hunk
           )
  end
end
