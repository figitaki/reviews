defmodule ReviewsWeb.ReviewLive.PacketComponents do
  @moduledoc false
  use ReviewsWeb, :html

  alias Reviews.PacketSectionDecisions
  alias Reviews.ReviewHunks
  alias Reviews.ReviewPacket
  alias Reviews.ReviewView

  attr :packet, :map, required: true
  attr :review, :any, required: true
  attr :patchsets, :list, required: true
  attr :section_decisions, :list, required: true
  attr :file_diffs, :list, required: true
  attr :hunks_by_path, :map, required: true
  attr :selected_patchset, :any, required: true
  attr :published_threads, :list, required: true
  attr :current_user, :any, required: true
  attr :diff_style, :string, required: true
  attr :expanded_section_ids, :any, required: true
  attr :expanded_hunk_ids, :any, required: true

  def packet(assigns) do
    sections = packet_sections(assigns)

    assigns =
      assigns
      |> assign(:sections, sections)
      |> assign(:file_labels, file_labels(assigns.file_diffs))

    ~H"""
    <section id="review-packet" class="review-packet" aria-labelledby="review-packet-title">
      <div class="review-packet-grid">
        <article
          :for={section <- @sections}
          id={"packet-section-#{section.index}"}
          class={[
            "review-packet-section",
            section.effective_status && "is-decided",
            section_expanded?(@expanded_section_ids, section.index) && "is-open"
          ]}
        >
          <header class="review-packet-section-summary">
            <button
              type="button"
              class="review-packet-section-heading"
              phx-click="toggle_packet_section"
              phx-value-section_index={section.index}
              aria-expanded={section_expanded?(@expanded_section_ids, section.index)}
              aria-controls={"packet-section-#{section.index}-body"}
            >
              <div class="review-packet-section-title-row">
                <h3 class="review-packet-section-title">{section.title}</h3>
                <span
                  class="review-packet-section-estimate"
                  title={"Estimated from #{section.estimate.changed_lines} changed lines across #{section.estimate.hunk_count} hunk rows."}
                >
                  {section.estimate.effort}
                  <.change_stat
                    additions={section.estimate.additions}
                    deletions={section.estimate.deletions}
                  /> ~{section.estimate.time}
                </span>
              </div>
            </button>

            <div class="review-packet-section-controls">
              <span
                :if={section.previous}
                class={[
                  "review-section-state-pill",
                  "is-previous",
                  "is-#{section.previous.status}"
                ]}
                title={"Previously #{section.previous.status} in v#{section.previous.patchset_number}"}
                aria-label={"Previously #{section.previous.status} in version #{section.previous.patchset_number}"}
              >
                <.section_status_icon status={section.previous.status} />
                <span class="sr-only">
                  Previously {section.previous.status} in v{section.previous.patchset_number}
                </span>
              </span>

              <.icon
                :if={section.previous}
                name="hero-chevron-right"
                class="review-section-transition-icon"
              />

              <div
                class="review-packet-section-actions"
                aria-label={"Decision for #{section.title}"}
              >
                <%= if @current_user do %>
                  <button
                    :for={status <- ~w(approved denied ignored)}
                    type="button"
                    class={[
                      "review-section-action",
                      section.effective_status == status && "is-active",
                      "is-#{status}"
                    ]}
                    title={section_status_label(status)}
                    aria-label={section_status_label(status)}
                    phx-click="set_section_status"
                    phx-value-section_index={section.index}
                    phx-value-status={status}
                  >
                    <.section_status_icon status={status} />
                    <span class="review-section-action-label">{section_status_label(status)}</span>
                  </button>
                <% else %>
                  <span class="review-packet-section-signin">Sign in to review</span>
                <% end %>
              </div>

              <button
                type="button"
                class="review-packet-section-toggle"
                phx-click="toggle_packet_section"
                phx-value-section_index={section.index}
                aria-expanded={section_expanded?(@expanded_section_ids, section.index)}
                aria-controls={"packet-section-#{section.index}-body"}
              >
                <span class="sr-only">Toggle {section.title}</span>
                <.icon name="hero-chevron-down" class="review-collapse-icon" />
              </button>
            </div>
          </header>

          <p
            :if={section.summary != "" && !section_expanded?(@expanded_section_ids, section.index)}
            class="review-packet-section-summary-text"
          >
            {section.summary}
          </p>

          <div
            :if={section_expanded?(@expanded_section_ids, section.index)}
            id={"packet-section-#{section.index}-body"}
            class="review-packet-section-body"
          >
            <div class="review-packet-row-list">
              <.packet_unit
                :for={unit <- packet_units(section, @hunks_by_path)}
                unit={unit}
                file_diffs={@file_diffs}
                selected_patchset={@selected_patchset}
                published_threads={@published_threads}
                current_user={@current_user}
                diff_style={@diff_style}
                hunks_by_path={@hunks_by_path}
                expanded_hunk_ids={@expanded_hunk_ids}
                section_title={section.title}
                file_labels={@file_labels}
              />
            </div>
          </div>
        </article>

        <section :if={@sections == []} class="review-packet-section">
          <h3 class="review-packet-section-title">No sections</h3>
          <p class="review-packet-md-paragraph">This packet does not include narrative sections.</p>
        </section>
      </div>
    </section>
    """
  end

  def packet_effort_for_header(
        packet,
        file_diffs,
        hunks_by_path,
        section_decisions,
        selected_patchset,
        patchsets
      ) do
    %{
      packet: packet,
      file_diffs: file_diffs,
      hunks_by_path: hunks_by_path,
      section_decisions: section_decisions,
      selected_patchset: selected_patchset,
      patchsets: patchsets
    }
    |> packet_sections()
    |> packet_effort()
  end

  defp packet_sections(assigns) do
    selected_patchset = assigns.selected_patchset

    assigns.packet
    |> ReviewPacket.sections()
    |> Enum.map(fn section ->
      state =
        PacketSectionDecisions.section_state(
          section,
          assigns.section_decisions,
          selected_patchset,
          assigns.patchsets
        )

      section
      |> Map.put(:status, state.current && state.current.status)
      |> Map.put(:effective_status, state.effective && state.effective.status)
      |> Map.put(:previous, state.previous)
      |> Map.put(:summary, section_summary(section))
      |> Map.put(:estimate, section_estimate(section, assigns.hunks_by_path))
    end)
  end

  defp section_expanded?(expanded_section_ids, section_index) do
    MapSet.member?(expanded_section_ids, section_index)
  end

  defp packet_effort(sections) do
    minutes = Enum.sum(Enum.map(sections, & &1.estimate.minutes))
    buckets = effort_buckets(sections)

    %{
      minutes: minutes,
      remaining_minutes: buckets.pending,
      time: format_minutes(minutes),
      remaining_time: format_minutes(buckets.pending),
      effort: effort_label(minutes),
      progress_label: progress_label(buckets, minutes)
    }
  end

  defp effort_buckets(sections) do
    Enum.reduce(sections, %{approved: 0, denied: 0, ignored: 0, pending: 0}, fn section, acc ->
      key =
        case section.effective_status do
          "approved" -> :approved
          "denied" -> :denied
          "ignored" -> :ignored
          _ -> :pending
        end

      Map.update!(acc, key, &(&1 + section.estimate.minutes))
    end)
  end

  defp progress_label(buckets, total) do
    "Approved #{format_minutes(buckets.approved)} of #{format_minutes(total)}; denied #{format_minutes(buckets.denied)}; ignored #{format_minutes(buckets.ignored)}."
  end

  defp section_summary(section) do
    section.rows
    |> Enum.find_value("", fn row ->
      if ReviewPacket.text(row, "kind") == "markdown" do
        row
        |> ReviewPacket.text("body")
        |> markdown_summary()
        |> blank_to_nil()
      end
    end)
  end

  defp markdown_summary(body) do
    body
    |> String.split("\n\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.find_value("", fn block ->
      block
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" || String.starts_with?(&1, "#")))
      |> case do
        [] -> nil
        lines -> lines |> Enum.join(" ") |> plain_markdown() |> truncate_summary()
      end
    end)
  end

  defp plain_markdown(text) do
    text
    |> String.replace(~r/`([^`]+)`/, "\\1")
    |> String.replace(~r/\*\*([^*]+)\*\*/, "\\1")
    |> String.replace(~r/\*([^*]+)\*/, "\\1")
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp truncate_summary(text) do
    text = String.trim(text)

    if String.length(text) > 150 do
      text |> String.slice(0, 147) |> String.trim_trailing() |> Kernel.<>("...")
    else
      text
    end
  end

  def file_labels(file_diffs) do
    paths = Enum.map(file_diffs, & &1.path)

    Map.new(paths, fn path ->
      {path, shortest_unique_suffix(path, paths)}
    end)
  end

  defp shortest_unique_suffix(path, paths) do
    parts = String.split(path || "", "/", trim: true)
    max_depth = max(length(parts), 1)

    1..max_depth
    |> Enum.find_value(Path.basename(path || ""), fn depth ->
      candidate = suffix(parts, depth)

      if Enum.count(paths, &(suffix(String.split(&1 || "", "/", trim: true), depth) == candidate)) ==
           1 do
        candidate
      end
    end)
  end

  defp suffix([], _depth), do: ""

  defp suffix(parts, depth) do
    parts
    |> Enum.take(-depth)
    |> Enum.join("/")
  end

  defp section_estimate(section, hunks_by_path) do
    {additions, deletions, hunk_count, viewed_count} =
      Enum.reduce(section.rows, {0, 0, 0, 0}, fn row, {additions, deletions, hunks, viewed} ->
        if ReviewPacket.text(row, "kind") == "hunk" do
          case ReviewHunks.for_packet_row(hunks_by_path, row) do
            nil ->
              {additions, deletions, hunks, viewed}

            hunk ->
              {
                additions + hunk.display_additions,
                deletions + hunk.display_deletions,
                hunks + 1,
                viewed + if(hunk.viewed?, do: 1, else: 0)
              }
          end
        else
          {additions, deletions, hunks, viewed}
        end
      end)

    changed_lines = additions + deletions

    minutes =
      changed_lines
      |> estimate_minutes(hunk_count)

    %{
      additions: additions,
      deletions: deletions,
      changed_lines: changed_lines,
      hunk_count: hunk_count,
      viewed_count: viewed_count,
      minutes: minutes,
      time: format_minutes(minutes),
      effort: effort_label(minutes)
    }
  end

  defp estimate_minutes(0, 0), do: 1

  defp estimate_minutes(changed_lines, hunk_count) do
    line_minutes = max(1, ceil(changed_lines / 45))
    hunk_minutes = div(max(hunk_count - 1, 0), 3)
    line_minutes + hunk_minutes
  end

  defp format_minutes(1), do: "1 min"
  defp format_minutes(minutes) when minutes > 59, do: format_hours(minutes)
  defp format_minutes(minutes), do: "#{minutes} min"

  defp format_hours(minutes) do
    half_hour_steps = max(2, round(minutes / 30))

    label =
      if rem(half_hour_steps, 2) == 0 do
        "#{div(half_hour_steps, 2)}hr"
      else
        "#{div(half_hour_steps, 2)}.5hr"
      end

    "~" <> label
  end

  defp effort_label(minutes) when minutes <= 2, do: "Light"
  defp effort_label(minutes) when minutes <= 6, do: "Moderate"
  defp effort_label(minutes) when minutes <= 12, do: "Involved"
  defp effort_label(_minutes), do: "Deep"

  defp section_status_label("approved"), do: "Approve"
  defp section_status_label("denied"), do: "Deny"
  defp section_status_label("ignored"), do: "Ignore"
  defp section_status_label(status), do: status

  attr :additions, :integer, required: true
  attr :deletions, :integer, required: true

  def change_stat(assigns) do
    ~H"""
    <span
      class="review-change-stat"
      aria-label={"#{@additions} additions and #{@deletions} deletions"}
    >
      <span :if={@additions > 0} class="review-change-stat-add">+{@additions}</span>
      <span :if={@deletions > 0} class="review-change-stat-del">-{@deletions}</span>
      <span :if={@additions == 0 && @deletions == 0} class="review-change-stat-empty">±0</span>
    </span>
    """
  end

  attr :status, :string, required: true

  defp section_status_icon(assigns) do
    assigns =
      assign(
        assigns,
        :icon,
        case assigns.status do
          "approved" -> "hero-check"
          "denied" -> "hero-x-mark"
          "ignored" -> "hero-minus"
          _ -> "hero-minus"
        end
      )

    ~H"""
    <.icon name={@icon} class="review-section-state-icon" />
    """
  end

  attr :row, :map, required: true
  attr :row_id, :string, required: true
  attr :file_diffs, :list, required: true
  attr :selected_patchset, :any, required: true
  attr :published_threads, :list, required: true
  attr :current_user, :any, required: true
  attr :diff_style, :string, required: true
  attr :hunks_by_path, :map, required: true
  attr :expanded_hunk_ids, :any, required: true
  attr :section_title, :string, default: nil
  attr :file_label, :string, default: nil

  def packet_row(%{row: row} = assigns) do
    assigns =
      assigns
      |> assign(:kind, ReviewPacket.text(row, "kind"))
      |> assign(:body, ReviewPacket.text(row, "body"))
      |> assign(:annotation?, annotation_markdown?(ReviewPacket.text(row, "body")))
      |> assign(:path, ReviewPacket.text(row, "path"))
      |> assign(:hunk_index, ReviewPacket.int(row, "hunk_index"))
      |> assign(:line_start, ReviewPacket.int(row, "line_start"))
      |> assign(:line_end, ReviewPacket.int(row, "line_end"))
      |> assign(:file, file_for(assigns.file_diffs, ReviewPacket.text(row, "path")))
      |> assign(:hunk, ReviewHunks.for_packet_row(assigns.hunks_by_path, row))
      |> assign(:section_index, section_index_from_row_id(assigns.row_id))

    ~H"""
    <%= cond do %>
      <% @kind == "hunk" && @file && @hunk -> %>
        <div id={@row_id} class="review-packet-row is-hunk">
          <.hunk_card
            hunk={@hunk}
            hunk_id={@hunk.id}
            file={@file}
            selected_patchset={@selected_patchset}
            published_threads={@published_threads}
            current_user={@current_user}
            diff_style={@diff_style}
            expanded_hunk_ids={@expanded_hunk_ids}
            section_index={@section_index}
            section_title={@section_title}
            file_label={@file_label}
          />
        </div>
      <% @kind == "hunk" -> %>
        <span id={@row_id} class="review-packet-hunk is-unresolved" translate="no">
          <.icon name="hero-code-bracket-square" class="size-4" />
          {ReviewPacket.row_ref(@row)}
        </span>
      <% true -> %>
        <div
          id={@row_id}
          class={["review-packet-row is-markdown", @annotation? && "is-annotation"]}
          phx-hook={if(@annotation?, do: nil, else: "StickyProse")}
        >
          <.markdown body={@body} class="review-packet-markdown" />
        </div>
    <% end %>
    """
  end

  defp annotation_markdown?(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> List.first("")
    |> String.trim()
    |> String.starts_with?("### ")
  end

  defp annotation_markdown?(_body), do: false

  def packet_hunk_id(row_id, hunk) do
    "#{row_id}--#{hunk.id}"
  end

  def packet_units(section, hunks_by_path) do
    section.rows
    |> Enum.with_index()
    |> Enum.reduce([], fn {row, index}, units ->
      row_id = "packet-section-#{section.index}-row-#{index}"
      hunk = hunk_for_packet_row(hunks_by_path, row)

      cond do
        hunk && continues_hunk_group?(List.first(units), hunk) ->
          [append_hunk_to_group(List.first(units), row, row_id, hunk) | tl(units)]

        hunk ->
          [new_hunk_group(row, row_id, hunk) | units]

        true ->
          [%{kind: :row, row: row, row_id: row_id} | units]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(&finalize_packet_unit/1)
  end

  defp hunk_for_packet_row(hunks_by_path, row) do
    if ReviewPacket.text(row, "kind") == "hunk" do
      ReviewHunks.for_packet_row(hunks_by_path, row)
    end
  end

  defp continues_hunk_group?(%{kind: :hunk_group, hunks: [previous | _]}, hunk) do
    previous.file_path == hunk.file_path && previous.hunk_index + 1 == hunk.hunk_index
  end

  defp continues_hunk_group?(_unit, _hunk), do: false

  defp append_hunk_to_group(group, row, row_id, hunk) do
    %{group | rows: group.rows ++ [{row, row_id}], hunks: [hunk | group.hunks]}
  end

  defp new_hunk_group(row, row_id, hunk) do
    %{kind: :hunk_group, rows: [{row, row_id}], hunks: [hunk]}
  end

  defp finalize_packet_unit(%{kind: :hunk_group, hunks: hunks} = group) do
    hunks = Enum.reverse(hunks)
    row_id = group.rows |> List.first() |> elem(1)
    combined_hunk = ReviewHunks.combine_consecutive(hunks)
    combined_hunk = %{combined_hunk | id: packet_hunk_id(row_id, combined_hunk)}

    %{
      kind: :hunk_group,
      row_id: row_id,
      row_ids: Enum.map(group.rows, &elem(&1, 1)),
      row: group.rows |> List.first() |> elem(0),
      hunk: combined_hunk,
      grouped?: length(hunks) > 1
    }
  end

  defp finalize_packet_unit(unit), do: unit

  attr :unit, :map, required: true
  attr :file_diffs, :list, required: true
  attr :selected_patchset, :any, required: true
  attr :published_threads, :list, required: true
  attr :current_user, :any, required: true
  attr :diff_style, :string, required: true
  attr :hunks_by_path, :map, required: true
  attr :expanded_hunk_ids, :any, required: true
  attr :section_title, :string, default: nil
  attr :file_labels, :map, required: true

  def packet_unit(%{unit: %{kind: :hunk_group} = unit} = assigns) do
    row = unit.row
    file = file_for(assigns.file_diffs, ReviewPacket.text(row, "path"))

    assigns =
      assigns
      |> assign(:row_id, unit.row_id)
      |> assign(:row_ids, unit.row_ids)
      |> assign(:file, file)
      |> assign(:hunk, unit.hunk)
      |> assign(:grouped?, unit.grouped?)
      |> assign(:section_index, section_index_from_row_id(unit.row_id))
      |> assign(:file_label, Map.get(assigns.file_labels, ReviewPacket.text(row, "path")))

    ~H"""
    <div id={@row_id} class="review-packet-row is-hunk" data-packet-row-ids={Enum.join(@row_ids, " ")}>
      <.hunk_card
        hunk={@hunk}
        hunk_id={@hunk.id}
        file={@file}
        selected_patchset={@selected_patchset}
        published_threads={@published_threads}
        current_user={@current_user}
        diff_style={@diff_style}
        expanded_hunk_ids={@expanded_hunk_ids}
        section_index={@section_index}
        section_title={@section_title}
        file_label={@file_label}
        grouped?={@grouped?}
      />
    </div>
    """
  end

  def packet_unit(%{unit: %{kind: :row, row: row, row_id: row_id}} = assigns) do
    assigns =
      assigns
      |> assign(:row, row)
      |> assign(:row_id, row_id)
      |> assign(:file_label, Map.get(assigns.file_labels, ReviewPacket.text(row, "path")))

    ~H"""
    <.packet_row
      row={@row}
      row_id={@row_id}
      file_diffs={@file_diffs}
      selected_patchset={@selected_patchset}
      published_threads={@published_threads}
      current_user={@current_user}
      diff_style={@diff_style}
      hunks_by_path={@hunks_by_path}
      expanded_hunk_ids={@expanded_hunk_ids}
      section_title={@section_title}
      file_label={@file_label}
    />
    """
  end

  attr :hunk, :map, required: true
  attr :hunk_id, :string, required: true
  attr :file, :map, required: true
  attr :selected_patchset, :any, required: true
  attr :published_threads, :list, required: true
  attr :current_user, :any, required: true
  attr :diff_style, :string, required: true
  attr :expanded_hunk_ids, :any, required: true
  attr :section_index, :integer, default: nil
  attr :section_title, :string, default: nil
  attr :file_label, :string, default: nil
  attr :grouped?, :boolean, default: false
  attr :show_file_label?, :boolean, default: true
  attr :show_hunk_label?, :boolean, default: true
  attr :view_state, :any, default: nil
  attr :class, :string, default: nil

  def hunk_card(assigns) do
    assigns =
      assigns
      |> assign(:expanded?, MapSet.member?(assigns.expanded_hunk_ids, assigns.hunk_id))
      |> assign(:viewed?, assigns.hunk.viewed?)
      |> assign(:partially_viewed?, Map.get(assigns.hunk, :partially_viewed?, false))
      |> assign(
        :title,
        hunk_title(
          assigns.hunk,
          Map.get(assigns, :file_label),
          assigns.show_file_label?,
          assigns.show_hunk_label?
        )
      )
      |> assign(:details, hunk_details(assigns.hunk))
      |> assign(:hunk_attrs_json, hunk_attrs_json(assigns.hunk))

    ~H"""
    <article class={[
      "review-hunk-card",
      @class,
      @expanded? && "is-open",
      @viewed? && "is-viewed",
      @partially_viewed? && "is-partially-viewed"
    ]}>
      <header class="review-hunk-summary">
        <button
          type="button"
          class="review-hunk-toggle"
          phx-click="toggle_hunk_diff"
          phx-value-hunk_id={@hunk_id}
          aria-expanded={@expanded?}
          aria-controls={"#{@hunk_id}-body"}
          title={@details}
        >
          <.icon name="hero-chevron-down" class="review-collapse-icon" />
          <span class="review-hunk-title">
            <span :if={@title.file != ""} class="review-hunk-filename">{@title.file}</span>
            <span :if={@title.file != "" && @title.hunk != ""} class="review-hunk-separator">·</span>
            <span :if={@title.hunk != ""} class="review-hunk-index">{@title.hunk}</span>
            <span :if={@title.hunk != "" && @title.lines != ""} class="review-hunk-separator">·</span>
            <span :if={@title.lines != ""} class="review-hunk-lines">{@title.lines}</span>
          </span>
        </button>

        <div class="review-hunk-meta">
          <span
            :if={@view_state}
            class={[
              "review-file-view-state",
              "is-#{@view_state.status}"
            ]}
          >
            {@view_state.label}
          </span>
          <button
            :if={@current_user && !@viewed?}
            type="button"
            class="review-button review-button-ghost review-hunk-action"
            phx-click="mark_hunk_viewed"
            phx-value-file_path={@hunk.file_path}
            phx-value-row_ref={@hunk.row_ref}
            phx-value-hunk_fingerprint={@hunk.hunk_fingerprint}
            phx-value-hunk_id={@hunk_id}
            phx-value-hunk_attrs={@hunk_attrs_json}
            phx-value-hunk_index={@hunk.hunk_index}
            phx-value-line_start={@hunk.line_start}
            phx-value-line_end={@hunk.line_end}
            phx-value-section_index={@section_index}
            phx-value-section_title={@section_title}
          >
            Mark Viewed
          </button>
          <button
            :if={@current_user && @viewed?}
            type="button"
            class="review-hunk-viewed-pill review-hunk-viewed-button"
            phx-click="mark_hunk_unviewed"
            phx-value-file_path={@hunk.file_path}
            phx-value-row_ref={@hunk.row_ref}
            phx-value-hunk_fingerprint={@hunk.hunk_fingerprint}
            phx-value-hunk_id={@hunk_id}
            phx-value-hunk_attrs={@hunk_attrs_json}
            phx-value-hunk_index={@hunk.hunk_index}
            phx-value-line_start={@hunk.line_start}
            phx-value-line_end={@hunk.line_end}
            phx-value-section_index={@section_index}
            phx-value-section_title={@section_title}
            title="Mark unviewed"
          >
            Viewed
          </button>
          <span :if={@current_user && @partially_viewed?} class="review-hunk-partial-pill">
            Partially viewed
          </span>
        </div>
      </header>

      <div :if={@expanded?} id={"#{@hunk_id}-body"} class="review-hunk-body">
        <div class="review-packet-inline-diff">
          <div
            id={"#{@hunk_id}-diff"}
            phx-hook="DiffRenderer"
            phx-update="ignore"
            data-file-id={"hunk-#{@file.id}-#{@hunk_id}"}
            data-file-path={@file.path}
            data-file-status={@file.status}
            data-side="new"
            data-patchset-number={@selected_patchset && @selected_patchset.number}
            data-raw-diff={@hunk.display_raw_diff}
            data-threads={threads_json(@published_threads, @file.path)}
            data-signed-in={if @current_user, do: "true", else: "false"}
            data-diff-style={@diff_style}
          >
          </div>
        </div>
      </div>
    </article>
    """
  end

  defp hunk_attrs_json(%{grouped_hunks: hunks}) do
    hunks
    |> Enum.map(&hunk_attrs/1)
    |> Jason.encode!()
  end

  defp hunk_attrs_json(_hunk), do: nil

  defp hunk_attrs(hunk) do
    %{
      file_path: hunk.file_path,
      row_ref: hunk.row_ref,
      hunk_fingerprint: hunk.hunk_fingerprint,
      hunk_index: hunk.hunk_index,
      line_start: hunk.line_start,
      line_end: hunk.line_end
    }
  end

  defp hunk_title(hunk, file_label, show_file_label?, show_hunk_label?) do
    %{
      file: if(show_file_label?, do: file_label || Path.basename(hunk.file_path || ""), else: ""),
      hunk: if(show_hunk_label?, do: hunk_index_label(hunk), else: ""),
      lines: if(show_hunk_label?, do: hunk_line_label(hunk), else: "")
    }
  end

  defp hunk_index_label(%{hunk_indices: [first | _] = indices}) when length(indices) > 1 do
    "hunks #{first}-#{List.last(indices)}"
  end

  defp hunk_index_label(hunk), do: "hunk #{hunk.hunk_index}"

  defp hunk_line_label(%{hunk_indices: [_first, _second | _rest]}), do: ""

  defp hunk_line_label(%{line_start: line_start, line_end: line_end})
       when is_integer(line_start) and is_integer(line_end) do
    "L#{line_start}-L#{line_end}"
  end

  defp hunk_line_label(%{hunk_header: hunk_header}) when is_binary(hunk_header), do: hunk_header
  defp hunk_line_label(_hunk), do: ""

  defp hunk_details(hunk) do
    line_ref =
      cond do
        hunk.line_start && hunk.line_end -> "L#{hunk.line_start}-L#{hunk.line_end}"
        hunk.hunk_header != "" -> hunk.hunk_header
        true -> "line range unavailable"
      end

    stats = "#{hunk.display_additions} additions, #{hunk.display_deletions} deletions"

    "#{hunk.file_path} · hunk #{hunk.hunk_index} · #{line_ref} · #{stats}"
  end

  attr :body, :string, required: true
  attr :class, :string, default: "review-packet-markdown"

  def markdown(assigns) do
    assigns = assign(assigns, :blocks, markdown_blocks(assigns.body))

    ~H"""
    <div class={@class}>
      <%= for block <- @blocks do %>
        <h3
          :if={block.kind == :heading && block.level == 3}
          class="review-packet-md-heading is-h3"
        >
          <.inline segments={block.segments} />
        </h3>
        <h4
          :if={block.kind == :heading && block.level == 4}
          class="review-packet-md-heading is-h4"
        >
          <.inline segments={block.segments} />
        </h4>
        <ul :if={block.kind == :list} class="review-packet-md-list">
          <li :for={item <- block.items}>
            <.inline segments={item} />
          </li>
        </ul>
        <p :if={block.kind == :paragraph} class="review-packet-md-paragraph">
          <.inline segments={block.segments} />
        </p>
      <% end %>
    </div>
    """
  end

  attr :segments, :list, required: true

  def inline(assigns) do
    ~H"""
    <%= for segment <- @segments do %>
      <code :if={segment.kind == :code} class="review-packet-inline-code">{segment.text}</code>
      <span :if={segment.kind == :text}>{segment.text}</span>
    <% end %>
    """
  end

  defp markdown_blocks(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> parse_markdown_blocks([])
    |> Enum.reverse()
  end

  defp markdown_blocks(_), do: []

  defp parse_markdown_blocks([], acc), do: acc

  defp parse_markdown_blocks([line | rest], acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        parse_markdown_blocks(rest, acc)

      heading = markdown_heading(trimmed) ->
        {level, heading_text} = heading

        parse_markdown_blocks(rest, [
          %{kind: :heading, level: level, segments: markdown_inline(heading_text)} | acc
        ])

      markdown_list_item?(trimmed) ->
        {items, rest} = take_markdown_list([line | rest], [])
        parse_markdown_blocks(rest, [%{kind: :list, items: items} | acc])

      true ->
        {paragraph, rest} = take_markdown_paragraph([line | rest], [])

        parse_markdown_blocks(rest, [
          %{kind: :paragraph, segments: markdown_inline(paragraph)} | acc
        ])
    end
  end

  defp markdown_heading(line) do
    case Regex.run(~r/^(####|###)\s+(.+)$/, line) do
      [_, marks, text] -> {String.length(marks), String.trim(text)}
      _ -> nil
    end
  end

  defp markdown_list_item?(line), do: String.starts_with?(line, "- ")

  defp take_markdown_list([], acc), do: {Enum.reverse(acc), []}

  defp take_markdown_list([line | rest], acc) do
    trimmed = String.trim(line)

    if markdown_list_item?(trimmed) do
      item =
        trimmed
        |> String.replace_prefix("- ", "")
        |> markdown_inline()

      take_markdown_list(rest, [item | acc])
    else
      {Enum.reverse(acc), [line | rest]}
    end
  end

  defp take_markdown_paragraph([line | rest], _acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" || markdown_heading(trimmed) || markdown_list_item?(trimmed) ->
        {"", [line | rest]}

      true ->
        {String.trim(line), rest}
    end
  end

  defp markdown_inline(text) when is_binary(text) do
    text
    |> String.split("`")
    |> Enum.with_index()
    |> Enum.reject(fn {part, _idx} -> part == "" end)
    |> Enum.map(fn {part, idx} ->
      %{kind: if(rem(idx, 2) == 1, do: :code, else: :text), text: part}
    end)
  end

  defp markdown_inline(_), do: []

  defp file_for(file_diffs, path) do
    Enum.find(file_diffs, &(&1.path == path || &1.old_path == path))
  end

  defp section_index_from_row_id(row_id) do
    case Regex.run(~r/^packet-section-(\d+)-row-\d+$/, row_id) do
      [_, index] -> String.to_integer(index)
      _ -> nil
    end
  end

  defp threads_json(threads, file_path) do
    snapshot = %{published_threads: threads}
    Jason.encode!(ReviewView.thread_payloads_for_file(snapshot, file_path))
  end
end
