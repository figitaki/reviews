defmodule ReviewsWeb.ReviewLive.PacketComponents do
  @moduledoc false
  use ReviewsWeb, :html

  alias Reviews.PacketSectionDecisions
  alias Reviews.ReviewPacket
  alias Reviews.ReviewView

  attr :packet, :map, required: true
  attr :review, :any, required: true
  attr :patchsets, :list, required: true
  attr :section_decisions, :list, required: true
  attr :file_diffs, :list, required: true
  attr :selected_patchset, :any, required: true
  attr :published_threads, :list, required: true
  attr :drafts, :list, required: true
  attr :current_user, :any, required: true
  attr :diff_style, :string, required: true
  attr :expanded_section_ids, :any, required: true

  def packet(assigns) do
    sections = packet_sections(assigns)

    assigns =
      assigns
      |> assign(:sections, sections)

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
                  <.change_stat
                    additions={section.estimate.additions}
                    deletions={section.estimate.deletions}
                  />
                  {section.estimate.time}
                  <span class={["review-effort-pill", "is-#{effort_class(section.estimate.effort)}"]}>
                    {section.estimate.effort}
                  </span>
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
              <.packet_row
                :for={{row, idx} <- Enum.with_index(section.rows)}
                row={row}
                row_id={"packet-section-#{section.index}-row-#{idx}"}
                file_diffs={@file_diffs}
                selected_patchset={@selected_patchset}
                published_threads={@published_threads}
                drafts={@drafts}
                current_user={@current_user}
                diff_style={@diff_style}
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
        section_decisions,
        selected_patchset,
        patchsets
      ) do
    %{
      packet: packet,
      file_diffs: file_diffs,
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
      |> Map.put(:estimate, section_estimate(section, assigns.file_diffs))
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

  defp truncate_summary(text) do
    text = String.trim(text)

    if String.length(text) > 150 do
      text |> String.slice(0, 147) |> String.trim_trailing() |> Kernel.<>("...")
    else
      text
    end
  end

  defp section_estimate(section, file_diffs) do
    {additions, deletions, hunk_count} =
      Enum.reduce(section.rows, {0, 0, 0}, fn row, {additions, deletions, hunks} ->
        if ReviewPacket.text(row, "kind") == "hunk" do
          file = file_for(file_diffs, ReviewPacket.text(row, "path"))

          raw_diff =
            packet_row_raw_diff(
              file,
              ReviewPacket.int(row, "hunk_index"),
              ReviewPacket.int(row, "line_start"),
              ReviewPacket.int(row, "line_end")
            )

          {row_additions, row_deletions} = changed_line_stats(raw_diff)

          {additions + row_additions, deletions + row_deletions, hunks + 1}
        else
          {additions, deletions, hunks}
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
      minutes: minutes,
      time: format_minutes(minutes),
      effort: effort_label(minutes)
    }
  end

  defp changed_line_stats(raw_diff) do
    Enum.reduce(String.split(raw_diff, "\n"), {0, 0}, fn line, {additions, deletions} ->
      cond do
        String.starts_with?(line, "+") && !String.starts_with?(line, "+++") ->
          {additions + 1, deletions}

        String.starts_with?(line, "-") && !String.starts_with?(line, "---") ->
          {additions, deletions + 1}

        true ->
          {additions, deletions}
      end
    end)
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

  defp effort_class("Light"), do: "light"
  defp effort_class("Moderate"), do: "moderate"
  defp effort_class("Involved"), do: "involved"
  defp effort_class("Deep"), do: "deep"
  defp effort_class(_), do: "moderate"

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
  attr :drafts, :list, required: true
  attr :current_user, :any, required: true
  attr :diff_style, :string, required: true

  def packet_row(%{row: row} = assigns) do
    assigns =
      assigns
      |> assign(:kind, ReviewPacket.text(row, "kind"))
      |> assign(:body, ReviewPacket.text(row, "body"))
      |> assign(:path, ReviewPacket.text(row, "path"))
      |> assign(:hunk_index, ReviewPacket.int(row, "hunk_index"))
      |> assign(:line_start, ReviewPacket.int(row, "line_start"))
      |> assign(:line_end, ReviewPacket.int(row, "line_end"))
      |> assign(:file, file_for(assigns.file_diffs, ReviewPacket.text(row, "path")))

    assigns =
      assign(
        assigns,
        :raw_diff,
        packet_row_raw_diff(
          assigns.file,
          assigns.hunk_index,
          assigns.line_start,
          assigns.line_end
        )
      )

    ~H"""
    <%= cond do %>
      <% @kind == "hunk" && @file && @raw_diff != "" -> %>
        <div id={@row_id} class="review-packet-row is-hunk">
          <div class="review-packet-inline-diff">
            <div
              id={"#{@row_id}-diff"}
              phx-hook="DiffRenderer"
              phx-update="ignore"
              data-file-id={"packet-#{@file.id}-#{@row_id}"}
              data-file-path={@file.path}
              data-file-status={@file.status}
              data-side="new"
              data-patchset-number={@selected_patchset && @selected_patchset.number}
              data-raw-diff={@raw_diff}
              data-threads={threads_json(@published_threads, @file.path)}
              data-drafts={drafts_json(@drafts, @file.path, @current_user)}
              data-signed-in={if @current_user, do: "true", else: "false"}
              data-diff-style={@diff_style}
            >
            </div>
          </div>
        </div>
      <% @kind == "hunk" -> %>
        <span id={@row_id} class="review-packet-hunk is-unresolved" translate="no">
          <.icon name="hero-code-bracket-square" class="size-4" />
          {ReviewPacket.row_ref(@row)}
        </span>
      <% true -> %>
        <div id={@row_id} class="review-packet-row is-markdown">
          <.markdown body={@body} class="review-packet-markdown" />
        </div>
    <% end %>
    """
  end

  defp packet_row_raw_diff(nil, _hunk_index, _line_start, _line_end), do: ""

  defp packet_row_raw_diff(file, hunk_index, line_start, line_end) do
    slice_raw_diff(file.raw_diff || "", hunk_index, line_start, line_end)
  end

  defp slice_raw_diff(raw_diff, hunk_index, line_start, line_end)
       when is_integer(hunk_index) and hunk_index > 0 do
    lines = String.split(raw_diff, "\n", trim: false)
    {header_lines, rest} = Enum.split_while(lines, &(not String.starts_with?(&1, "@@ ")))

    {_, selected} =
      Enum.reduce(rest, {0, []}, fn line, {idx, acc} ->
        cond do
          String.starts_with?(line, "@@ ") ->
            next_idx = idx + 1
            {next_idx, if(next_idx == hunk_index, do: [line], else: acc)}

          idx == hunk_index ->
            {idx, acc ++ [line]}

          true ->
            {idx, acc}
        end
      end)

    case selected do
      [] ->
        ""

      [hunk_header | hunk_lines] ->
        hunk_lines = slice_hunk_lines(hunk_lines, line_start, line_end)
        Enum.join(header_lines ++ [hunk_header | hunk_lines], "\n")
    end
  end

  defp slice_raw_diff(_raw_diff, _hunk_index, _line_start, _line_end), do: ""

  defp slice_hunk_lines(lines, nil, nil), do: Enum.reject(lines, &(&1 == ""))

  defp slice_hunk_lines(lines, line_start, line_end)
       when is_integer(line_start) and is_integer(line_end) do
    lines
    |> Enum.reject(&(&1 == ""))
    |> Enum.slice((line_start - 1)..(line_end - 1))
  end

  defp slice_hunk_lines(lines, _line_start, _line_end), do: Enum.reject(lines, &(&1 == ""))

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

  defp take_markdown_paragraph([], acc), do: {trim_paragraph(acc), []}

  defp take_markdown_paragraph([line | rest], acc) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" || markdown_heading(trimmed) || markdown_list_item?(trimmed) ->
        {trim_paragraph(acc), [line | rest]}

      true ->
        take_markdown_paragraph(rest, [String.trim(line) | acc])
    end
  end

  defp trim_paragraph(lines) do
    lines
    |> Enum.reverse()
    |> Enum.join(" ")
    |> String.trim()
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

  defp threads_json(threads, file_path) do
    snapshot = %{published_threads: threads}
    Jason.encode!(ReviewView.thread_payloads_for_file(snapshot, file_path))
  end

  defp drafts_json(drafts, file_path, viewer) do
    snapshot = %{drafts: drafts, viewer: viewer}
    Jason.encode!(ReviewView.draft_payloads_for_file(snapshot, file_path))
  end
end
