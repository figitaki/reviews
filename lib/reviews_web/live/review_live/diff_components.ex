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
        false
      )

    ~H"""
    <div class={["rev-shell", !@show_outline? && "is-outline-hidden"]}>
      <.guide_shell
        :if={@show_outline?}
        outline={@packet_outline}
        active_section_index={@active_section_index}
        open_threads_by_op={@open_threads_by_op}
        file_diffs={@file_diffs}
      />

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
  attr :open_threads_by_op, :list, required: true
  attr :file_diffs, :list, required: true

  defp guide_shell(assigns) do
    assigns =
      assigns
      |> assign(:active_section, active_section(assigns.outline, assigns.active_section_index))
      |> assign(:first_section, List.first(assigns.outline.sections || []))

    ~H"""
    <aside
      id="review-guide-shell"
      class="review-guide-shell"
      phx-hook="GuideFlyout"
      aria-label="Review guide"
    >
      <nav id="review-edge-rail" class="review-edge-rail" aria-label="Review sections">
        <button
          type="button"
          class="review-edge-rail-menu"
          data-guide-flyout-toggle
          aria-label="Open review map"
          aria-controls="review-guide-flyout"
          aria-expanded="false"
        >
          <.icon name="hero-bars-3" class="size-4" />
        </button>

        <div class="review-edge-rail-ticks">
          <button
            id="review-guide-overview-tick"
            type="button"
            class={["review-edge-tick", "is-overview", is_nil(@active_section_index) && "is-active"]}
            phx-click="select_packet_overview"
            aria-label="Packet overview"
            aria-current={if(is_nil(@active_section_index), do: "true", else: "false")}
          >
            <span aria-hidden="true">★</span>
          </button>

          <button
            :for={section <- @outline.sections}
            id={"review-guide-tick-#{section.index}"}
            type="button"
            class={[
              "review-edge-tick",
              section.index == @active_section_index && "is-active",
              section.effective_status && "is-#{section.effective_status}"
            ]}
            phx-click={if(section.target_id, do: "packet_nav_jump", else: "select_guide_section")}
            phx-value-section_index={section.index}
            phx-value-target_id={section.target_id}
            aria-label={"#{String.pad_leading(Integer.to_string(section.index + 1), 2, "0")} #{section.title}"}
            aria-current={if(section.index == @active_section_index, do: "true", else: "false")}
          >
            {String.pad_leading(Integer.to_string(section.index + 1), 2, "0")}
          </button>
        </div>

        <button
          type="button"
          class="review-edge-rail-hide review-packet-nav-hide"
          phx-click="toggle_packet_outline"
          title="Hide guide"
          aria-label="Hide guide"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </nav>

      <div
        id="review-guide-flyout"
        class="review-guide-flyout"
        data-guide-flyout-panel
        aria-label="Packet outline"
      >
        <div class="review-guide-flyout-group">
          <div class="review-guide-flyout-label">Packet</div>
          <button
            type="button"
            class={["review-guide-flyout-section", is_nil(@active_section_index) && "is-active"]}
            phx-click="select_packet_overview"
          >
            <span class="review-guide-flyout-num">★</span>
            <span>Overview</span>
          </button>
        </div>

        <div class="review-guide-flyout-group">
          <div class="review-guide-flyout-label">Sections</div>
          <div :for={section <- @outline.sections} class="review-guide-flyout-item">
            <button
              type="button"
              class={[
                "review-guide-flyout-section",
                section.index == @active_section_index && "is-active"
              ]}
              phx-click={if(section.target_id, do: "packet_nav_jump", else: "select_guide_section")}
              phx-value-section_index={section.index}
              phx-value-target_id={section.target_id}
            >
              <span class="review-guide-flyout-num">
                {String.pad_leading(Integer.to_string(section.index + 1), 2, "0")}
              </span>
              <span class="review-guide-flyout-title">{section.title}</span>
            </button>

            <div
              :if={section.index == @active_section_index && section.files != []}
              class="review-guide-flyout-files"
            >
              <button
                :for={file <- section.files}
                type="button"
                class="review-guide-flyout-file"
                phx-click="packet_nav_jump"
                phx-value-section_index={section.index}
                phx-value-target_id={file.target_id}
                disabled={is_nil(file.target_id)}
                translate="no"
              >
                {file.basename}
              </button>
            </div>
          </div>
        </div>
      </div>

      <section id="review-guide-panel" class="review-guide-panel" aria-live="polite">
        <.guide_overview_panel
          :if={is_nil(@active_section_index)}
          outline={@outline}
          first_section={@first_section}
        />

        <.guide_section_panel
          :if={@active_section}
          section={@active_section}
          section_count={@outline.summary.section_count}
        />

        <section
          :if={@open_threads_by_op != []}
          id="open-threads"
          class="rev-open-threads review-guide-open-threads"
          aria-label="Open threads"
        >
          <h2 class="rev-open-threads-heading">Open threads</h2>
          <.open_threads groups={@open_threads_by_op} file_diffs={@file_diffs} />
        </section>
      </section>
    </aside>
    """
  end

  attr :outline, :map, required: true
  attr :first_section, :map, default: nil

  defp guide_overview_panel(assigns) do
    ~H"""
    <div class="review-guide-panel-inner is-overview">
      <span class="review-guide-eyebrow">
        Overview · {@outline.summary.section_count} {plural(@outline.summary.section_count, "section")} · ~{@outline.summary.time}
      </span>
      <h2 class="review-guide-panel-title">{@outline.overview.title}</h2>
      <PacketComponents.markdown
        :if={@outline.overview.summary != ""}
        body={@outline.overview.summary}
        class="review-guide-panel-prose"
      />
      <p :if={@outline.overview.summary == ""} class="review-guide-panel-prose">
        This packet is organized into focused review sections. Start with the first section to follow the guide alongside the diff.
      </p>
      <div class="review-guide-overview-stats">
        <span>{@outline.summary.file_count} {plural(@outline.summary.file_count, "file")}</span>
        <PacketComponents.change_stat
          additions={@outline.summary.additions}
          deletions={@outline.summary.deletions}
        />
        <span>~{@outline.summary.time}</span>
      </div>
      <button
        :if={@first_section}
        type="button"
        class="review-guide-begin"
        phx-click={if(@first_section.target_id, do: "packet_nav_jump", else: "select_guide_section")}
        phx-value-section_index={@first_section.index}
        phx-value-target_id={@first_section.target_id}
      >
        Begin review <span aria-hidden="true">→</span>
      </button>
    </div>
    """
  end

  attr :section, :map, required: true
  attr :section_count, :integer, required: true

  defp guide_section_panel(assigns) do
    ~H"""
    <div class="review-guide-panel-inner">
      <span class="review-guide-eyebrow">
        Section {String.pad_leading(Integer.to_string(@section.index + 1), 2, "0")} / {String.pad_leading(
          Integer.to_string(@section_count),
          2,
          "0"
        )}
      </span>
      <h2 class="review-guide-panel-title">{@section.title}</h2>
      <p :if={@section.summary != ""} class="review-guide-panel-prose">
        {@section.summary}
      </p>
      <div class="review-guide-panel-meta">
        <span>{@section.estimate.effort}</span>
        <span>{@section.file_count} {plural(@section.file_count, "file")}</span>
        <PacketComponents.change_stat
          additions={@section.estimate.additions}
          deletions={@section.estimate.deletions}
        />
        <span>~{@section.estimate.time}</span>
      </div>
      <div :if={@section.files != []} class="review-guide-panel-files">
        <div class="review-guide-files-label">
          <span>Files</span>
          <span></span>
        </div>
        <button
          :for={file <- @section.files}
          type="button"
          class={["review-guide-file-row", "is-#{file.view_state.status}"]}
          phx-click="packet_nav_jump"
          phx-value-section_index={@section.index}
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
          <span class="review-guide-file-state">{file.view_state.label}</span>
        </button>
      </div>
    </div>
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

  defp active_section(%{sections: sections}, index) when is_integer(index) do
    Enum.find(sections, &(&1.index == index))
  end

  defp active_section(_outline, _index), do: nil

  defp active_section_index(%{sections: [first | _] = sections}, index) when is_integer(index) do
    if Enum.any?(sections, &(&1.index == index)), do: index, else: first.index
  end

  defp active_section_index(%{sections: _sections}, nil), do: nil
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
