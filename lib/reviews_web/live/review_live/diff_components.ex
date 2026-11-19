defmodule ReviewsWeb.ReviewLive.DiffComponents do
  @moduledoc false
  use ReviewsWeb, :html

  alias Reviews.ReviewHunks
  alias ReviewsWeb.ReviewLive.PacketComponents

  attr :file_diffs, :list, required: true
  attr :selected_patchset, :any, required: true
  attr :published_threads, :list, required: true
  attr :current_user, :any, required: true
  attr :diff_style, :string, required: true
  attr :expanded_hunk_ids, :any, required: true
  attr :hunks_by_path, :map, required: true

  def diff_shell(assigns) do
    assigns = assign(assigns, :file_labels, PacketComponents.file_labels(assigns.file_diffs))

    ~H"""
    <div class={["rev-shell", @file_diffs == [] && "is-outline-hidden"]}>
      <.file_tree :if={@selected_patchset && @file_diffs != []} file_diffs={@file_diffs} />
      <section :if={@selected_patchset} id="diff-files" class="review-hunk-list min-w-0">
        <div :for={fd <- @file_diffs} :key={fd.id} id={"file-#{fd.id}"} class="review-file-hunks">
          <% file_hunks = Map.get(@hunks_by_path, fd.path, []) %>
          <% file_state = file_view_state(file_hunks) %>
          <PacketComponents.hunk_card
            :if={file_hunks != []}
            hunk={file_hunk(file_hunks)}
            hunk_id={file_diff_id(fd)}
            file={fd}
            selected_patchset={@selected_patchset}
            published_threads={@published_threads}
            current_user={@current_user}
            diff_style={@diff_style}
            expanded_hunk_ids={@expanded_hunk_ids}
            file_label={Map.get(@file_labels, fd.path) || fd.path}
            show_hunk_label?={false}
            view_state={file_state}
            class="is-file-diff"
          />
          <p :if={file_hunks == []} class="rev-empty">
            No hunks in {fd.path}.
          </p>
        </div>

        <p :if={@file_diffs == []} class="rev-empty">
          No files in this patchset.
        </p>
      </section>
    </div>
    """
  end

  attr :file_diffs, :list, required: true
  attr :id, :string, default: "file-tree"

  # The diff view's file tree. Files group under their folder (up to two
  # levels deep), and a click scrolls to the file's card in the browser,
  # without a server round trip. Phones get it behind the Files button.
  def file_tree(assigns) do
    assigns =
      assigns
      |> assign(:folders, file_tree_folders(assigns.file_diffs))
      |> assign(:additions, Enum.sum(Enum.map(assigns.file_diffs, & &1.additions)))
      |> assign(:deletions, Enum.sum(Enum.map(assigns.file_diffs, & &1.deletions)))

    ~H"""
    <div class="rev-sidebar rev-file-tree-wrap">
      <button
        id={"#{@id}-toggle"}
        type="button"
        class="rev-file-tree-toggle"
        aria-controls={@id}
        aria-expanded="false"
        phx-click={
          JS.toggle_attribute({"aria-expanded", "true", "false"})
          |> JS.toggle_class("is-open", to: "##{@id}")
        }
      >
        <.icon name="hero-folder" class="size-4" />
        <span>Files</span>
        <span class="rev-tree-count">{length(@file_diffs)}</span>
        <.icon name="hero-chevron-down-micro" class="rev-file-tree-toggle-chevron" />
      </button>

      <nav id={@id} class="rev-file-tree" aria-label="Changed files">
        <div class="rev-tree-header">
          <PacketComponents.change_stat additions={@additions} deletions={@deletions} />
          <span class="rev-tree-scope">
            All files · {length(@file_diffs)} {plural(length(@file_diffs), "file")}
          </span>
        </div>
        <div :for={folder <- @folders} :key={folder.path} class="contents">
          <.file_tree_files
            :if={folder.path == ""}
            tree_id={@id}
            files={folder.files}
            class="is-root"
          />
          <details :if={folder.path != ""} class="rev-tree-folder" open>
            <summary class="rev-tree-row is-folder">
              <.icon name="hero-folder" class="rev-tree-folder-icon" />
              <span class="rev-tree-label rev-tree-dir" translate="no">{folder.path}/</span>
            </summary>
            <.file_tree_files tree_id={@id} files={folder.files} />
          </details>
        </div>
      </nav>
    </div>
    """
  end

  attr :tree_id, :string, required: true
  attr :files, :list, required: true
  attr :class, :string, default: nil

  defp file_tree_files(assigns) do
    ~H"""
    <div class={["rev-tree-children", @class]}>
      <button
        :for={{fd, rest} <- @files}
        :key={fd.id}
        id={"#{@tree_id}-row-#{fd.id}"}
        type="button"
        class="rev-tree-row"
        title={fd.path}
        phx-click={
          JS.dispatch("phx:packet_nav_jump", detail: %{id: "file-#{fd.id}"})
          |> JS.remove_class("is-open", to: "##{@tree_id}")
          |> JS.set_attribute({"aria-expanded", "false"}, to: "##{@tree_id}-toggle")
        }
      >
        <PacketComponents.tree_file_label name={Path.basename(fd.path)} directory={rest} />
        <PacketComponents.change_stat additions={fd.additions} deletions={fd.deletions} />
        <span class="rev-tree-badge-slot">
          <PacketComponents.tree_badge status={fd.status} />
        </span>
      </button>
    </div>
    """
  end

  # Folders in first-seen order, each with its files and the part of each
  # file's directory below the folder.
  defp file_tree_folders(file_diffs) do
    entries =
      Enum.map(file_diffs, fn fd ->
        dirs = fd.path |> Path.dirname() |> Path.split() |> Enum.reject(&(&1 == "."))
        {folder, rest} = Enum.split(dirs, 2)
        {Enum.join(folder, "/"), {fd, Enum.join(rest, "/")}}
      end)

    groups = Enum.group_by(entries, &elem(&1, 0), &elem(&1, 1))

    entries
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(&%{path: &1, files: Map.fetch!(groups, &1)})
  end

  defp file_hunk(hunks), do: ReviewHunks.combine_consecutive(hunks)

  defp file_diff_id(file), do: "file-diff-#{file.id}"

  defp file_view_state([]), do: %{status: "empty", label: "No hunks"}

  defp file_view_state(hunks) do
    viewed = Enum.count(hunks, & &1.viewed?)
    total = length(hunks)

    cond do
      viewed == 0 -> %{status: "unviewed", label: "#{total} #{plural(total, "hunk")}"}
      viewed == total -> %{status: "viewed", label: "Viewed"}
      true -> %{status: "partial", label: "#{viewed}/#{total} viewed"}
    end
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
