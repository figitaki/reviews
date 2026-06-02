defmodule ReviewsWeb.ReviewLive.DiffComponents do
  @moduledoc false
  use ReviewsWeb, :html

  alias Reviews.ReviewHunks
  alias Reviews.ReviewView
  alias ReviewsWeb.ReviewLive.PacketComponents

  attr :file_diffs, :list, required: true
  attr :open_threads_by_op, :list, required: true
  attr :selected_patchset, :any, required: true
  attr :published_threads, :list, required: true
  attr :current_user, :any, required: true
  attr :diff_style, :string, required: true
  attr :expanded_file_ids, :any, required: true
  attr :expanded_hunk_ids, :any, required: true
  attr :hunks_by_path, :map, required: true
  attr :packet_outline, :map, default: nil
  attr :active_section_index, :integer, default: nil
  attr :show_packet_outline, :boolean, default: false

  def diff_shell(assigns) do
    assigns =
      assigns
      |> assign(:file_labels, PacketComponents.file_labels(assigns.file_diffs))
      |> assign(
        :active_section_index,
        active_section_index(assigns.packet_outline, assigns.active_section_index)
      )
      |> assign(
        :show_outline?,
        assigns.diff_style == "unified" && assigns.show_packet_outline &&
          is_map(assigns.packet_outline)
      )

    ~H"""
    <div class={["rev-shell", !@show_outline? && "is-outline-hidden"]}>
      <aside :if={@show_outline?} id="review-guide-sidebar" class="rev-sidebar review-guide-sidebar">
        <.guide_rail outline={@packet_outline} active_section_index={@active_section_index} />

        <section
          :if={@open_threads_by_op != []}
          id="open-threads"
          class="rev-open-threads"
          aria-label="Open threads"
        >
          <h2 class="rev-open-threads-heading">Open threads</h2>
          <.open_threads
            groups={@open_threads_by_op}
            file_diffs={@file_diffs}
          />
        </section>
      </aside>

      <section :if={@selected_patchset} id="diff-files" class="review-hunk-list min-w-0">
        <div :for={fd <- @file_diffs} id={"file-#{fd.id}"} class="review-file-hunks">
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

  attr :outline, :map, required: true
  attr :active_section_index, :integer, default: nil

  defp guide_rail(assigns) do
    ~H"""
    <nav
      id="review-guide-rail"
      class="review-guide-rail"
      aria-label="Review guide"
      style={"--guide-progress: #{@outline.summary.progress_percent}%"}
    >
      <div class="review-guide-rail-header">
        <div>
          <span class="review-guide-rail-kicker">Guided review</span>
          <strong>Review map</strong>
        </div>
        <span class="review-guide-rail-count">
          {@outline.summary.section_count} {plural(@outline.summary.section_count, "section")}
        </span>
        <button
          type="button"
          class="review-packet-nav-hide"
          phx-click="toggle_packet_outline"
          title="Hide guide"
          aria-label="Hide guide"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>

      <div class="review-guide-rail-summary">
        <span>{@outline.summary.file_count} {plural(@outline.summary.file_count, "file")}</span>
        <PacketComponents.change_stat
          additions={@outline.summary.additions}
          deletions={@outline.summary.deletions}
        />
        <span>~{@outline.summary.time}</span>
      </div>

      <div class="review-guide-progress" aria-hidden="true">
        <span></span>
      </div>

      <div :if={@outline.sections != []} class="review-guide-section-list">
        <section
          :for={section <- @outline.sections}
          id={"review-guide-section-#{section.index}"}
          class={[
            "review-guide-section",
            section.index == @active_section_index && "is-active",
            section.effective_status && "is-#{section.effective_status}"
          ]}
        >
          <button
            type="button"
            class="review-guide-section-button"
            phx-click="packet_nav_jump"
            phx-value-section_index={section.index}
            phx-value-target_id={section.target_id}
            disabled={is_nil(section.target_id)}
            aria-current={if(section.index == @active_section_index, do: "true", else: "false")}
          >
            <span class="review-guide-section-marker">
              <span class="review-guide-section-index">
                {String.pad_leading(Integer.to_string(section.index + 1), 2, "0")}
              </span>
            </span>
            <span class="review-guide-section-main">
              <span class="review-guide-section-heading">
                <span class="review-guide-section-title">{section.title}</span>
                <span class="review-guide-section-status">{section.status_label}</span>
              </span>
              <span
                :if={section.index == @active_section_index && section.summary != ""}
                class="review-guide-section-summary"
              >
                {section.summary}
              </span>
              <span :if={section.index == @active_section_index} class="review-guide-section-meta">
                <span>{section.estimate.effort}</span>
                <span>{section.file_count} {plural(section.file_count, "file")}</span>
                <PacketComponents.change_stat
                  additions={section.estimate.additions}
                  deletions={section.estimate.deletions}
                />
                <span>~{section.estimate.time}</span>
              </span>
              <span
                :if={section.index != @active_section_index}
                class="review-guide-section-collapsed-meta"
              >
                {section.file_count} {plural(section.file_count, "file")} · ~{section.estimate.time}
              </span>
            </span>
          </button>

          <div
            :if={section.index == @active_section_index && section.files != []}
            class="review-guide-file-list"
          >
            <button
              :for={file <- section.files}
              type="button"
              class={[
                "review-guide-file-row",
                "is-#{file.view_state.status}"
              ]}
              phx-click="packet_nav_jump"
              phx-value-section_index={section.index}
              phx-value-target_id={file.target_id}
              disabled={is_nil(file.target_id)}
            >
              <.icon name="hero-document-text" class="review-guide-file-icon" />
              <span class="review-guide-file-name" translate="no">{file.basename}</span>
              <span :if={file.directory != ""} class="review-guide-file-path" translate="no">
                {file.directory}
              </span>
              <span class="review-guide-file-stat">
                <PacketComponents.change_stat additions={file.additions} deletions={file.deletions} />
              </span>
              <span class="review-guide-file-state">
                <.icon
                  :if={file.view_state.status == "viewed"}
                  name="hero-check"
                  class="size-3.5"
                />
                {file.view_state.label}
              </span>
            </button>
          </div>
        </section>
      </div>

      <p :if={@outline.sections == []} class="review-packet-nav-empty">
        No guide sections in this packet.
      </p>
    </nav>
    """
  end

  attr :groups, :list, required: true
  attr :file_diffs, :list, required: true

  defp open_threads(assigns) do
    ~H"""
    <div :for={{op, threads} <- @groups} class="rev-open-thread-group">
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
    """
  end

  defp anchor_line_hint(%{anchor: %{"line_number_hint" => hint}}), do: hint
  defp anchor_line_hint(_), do: nil

  defp file_id_for(file_diffs, file_path) do
    Enum.find_value(file_diffs, fn fd -> fd.path == file_path && fd.id end)
  end

  defp file_hunk(hunks), do: ReviewHunks.combine_consecutive(hunks)

  defp file_diff_id(file), do: "file-diff-#{file.id}"

  defp active_section_index(%{sections: [first | _] = sections}, index) when is_integer(index) do
    if Enum.any?(sections, &(&1.index == index)), do: index, else: first.index
  end

  defp active_section_index(%{sections: [first | _]}, _index), do: first.index
  defp active_section_index(_outline, _index), do: nil

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
