defmodule ReviewsWeb.ReviewLive.DiffComponents do
  @moduledoc false
  use ReviewsWeb, :html

  alias Reviews.ReviewView

  attr :file_diffs, :list, required: true
  attr :open_threads_by_op, :list, required: true
  attr :selected_patchset, :any, required: true
  attr :published_threads, :list, required: true
  attr :drafts, :list, required: true
  attr :current_user, :any, required: true
  attr :diff_style, :string, required: true

  def diff_shell(assigns) do
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

      <section :if={@selected_patchset} id="diff-files" class="space-y-6 min-w-0">
        <article
          :for={fd <- @file_diffs}
          id={"file-#{fd.id}"}
          class="rev-file-card"
        >
          <div
            id={"diff-#{fd.id}"}
            phx-hook="DiffRenderer"
            phx-update="ignore"
            data-file-id={fd.id}
            data-file-path={fd.path}
            data-file-status={fd.status}
            data-side="new"
            data-patchset-number={@selected_patchset.number}
            data-raw-diff={fd.raw_diff}
            data-threads={threads_json(@published_threads, fd.path)}
            data-drafts={drafts_json(@drafts, fd.path, @current_user)}
            data-signed-in={if @current_user, do: "true", else: "false"}
            data-diff-style={@diff_style}
          >
          </div>
        </article>

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

  defp threads_json(threads, file_path) do
    snapshot = %{published_threads: threads}
    Jason.encode!(ReviewView.thread_payloads_for_file(snapshot, file_path))
  end

  defp drafts_json(drafts, file_path, viewer) do
    snapshot = %{drafts: drafts, viewer: viewer}
    Jason.encode!(ReviewView.draft_payloads_for_file(snapshot, file_path))
  end
end
