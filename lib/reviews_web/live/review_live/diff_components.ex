defmodule ReviewsWeb.ReviewLive.DiffComponents do
  @moduledoc false
  use ReviewsWeb, :html

  alias Reviews.ReviewView
  alias ReviewsWeb.ReviewLive.PacketComponents

  attr :file_diffs, :list, required: true
  attr :open_threads_by_op, :list, required: true
  attr :selected_patchset, :any, required: true
  attr :published_threads, :list, required: true
  attr :drafts, :list, required: true
  attr :current_user, :any, required: true
  attr :diff_style, :string, required: true
  attr :expanded_file_ids, :any, required: true
  attr :expanded_hunk_ids, :any, required: true
  attr :hunks_by_path, :map, required: true

  def diff_shell(assigns) do
    assigns = assign(assigns, :file_labels, PacketComponents.file_labels(assigns.file_diffs))

    ~H"""
    <div class="rev-shell">
      <aside id="file-tree" class="rev-sidebar">
        <ul class="rev-file-list">
          <li :for={fd <- @file_diffs}>
            <a href={"#file-#{fd.id}"} class="rev-file-link">
              <span class="flex items-center gap-2 min-w-0">
                <.ds_status_mark status={fd.status} />
                <span class="rev-file-path truncate" translate="no">{fd.path}</span>
              </span>
              <span class="rev-file-stats">
                <span class="rev-stat-add">+{fd.additions}</span>
                <span class="rev-stat-del">-{fd.deletions}</span>
              </span>
            </a>
          </li>
          <li :if={@file_diffs == []}>
            <span class="rev-empty">No files in this patchset.</span>
          </li>
        </ul>

        <section
          :if={@open_threads_by_op != []}
          id="open-threads"
          class="rev-open-threads"
          aria-label="Open threads"
        >
          <h2 class="rev-open-threads-heading">Open threads</h2>
          <div :for={{op, threads} <- @open_threads_by_op} class="rev-open-thread-group">
            <header class="rev-open-thread-group-header">
              <img
                :if={op && op.avatar_url}
                src={op.avatar_url}
                alt=""
                width="16"
                height="16"
                loading="lazy"
                class="rdr-avatar"
              />
              <span>{(op && op.username) || "anonymous"}</span>
            </header>
            <button
              :for={t <- threads}
              type="button"
              class="rev-open-thread-entry"
              phx-click={
                JS.dispatch("reviews:scroll-to-anchor",
                  detail: %{
                    file_id: file_id_for(@file_diffs, t.file_path),
                    file_path: t.file_path,
                    side: t.side,
                    line_number_hint: anchor_line_hint(t)
                  }
                )
              }
            >
              <span class="rev-open-thread-meta">
                <span class="rev-open-thread-path" translate="no">
                  {t.file_path}<span :if={anchor_line_hint(t)}>:{anchor_line_hint(t)}</span>
                </span>
                <span class="rev-open-thread-snippet">
                  {ReviewView.first_comment_snippet(t)}
                </span>
              </span>
            </button>
          </div>
        </section>
      </aside>

      <section :if={@selected_patchset} id="diff-files" class="review-hunk-list min-w-0">
        <div :for={fd <- @file_diffs} id={"file-#{fd.id}"} class="review-file-hunks">
          <% file_hunks = Map.get(@hunks_by_path, fd.path, []) %>
          <% file_state = file_view_state(file_hunks) %>
          <header class="review-file-header">
            <span class="flex items-center gap-2 min-w-0">
              <.ds_status_mark status={fd.status} />
              <span class="rev-file-path truncate" translate="no">{fd.path}</span>
            </span>
            <span class="review-file-header-meta">
              <span class={[
                "review-file-view-state",
                "is-#{file_state.status}"
              ]}>
                {file_state.label}
              </span>
              <span class="rev-file-stats">
                <span class="rev-stat-add">+{fd.additions}</span>
                <span class="rev-stat-del">-{fd.deletions}</span>
              </span>
            </span>
          </header>
          <PacketComponents.hunk_card
            :for={hunk <- file_hunks}
            hunk={hunk}
            hunk_id={hunk.id}
            file={fd}
            selected_patchset={@selected_patchset}
            published_threads={@published_threads}
            drafts={@drafts}
            current_user={@current_user}
            diff_style={@diff_style}
            expanded_hunk_ids={@expanded_hunk_ids}
            file_label={Map.get(@file_labels, fd.path)}
            show_file_label?={false}
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

  defp anchor_line_hint(%{anchor: %{"line_number_hint" => hint}}), do: hint
  defp anchor_line_hint(_), do: nil

  defp file_id_for(file_diffs, file_path) do
    Enum.find_value(file_diffs, fn fd -> fd.path == file_path && fd.id end)
  end

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
