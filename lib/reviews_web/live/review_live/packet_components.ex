defmodule ReviewsWeb.ReviewLive.PacketComponents do
  @moduledoc false
  use ReviewsWeb, :html

  alias Reviews.ReviewNavigation
  alias Reviews.ReviewView

  attr :packet, :map, required: true
  attr :file_diffs, :list, required: true
  attr :selected_patchset, :any, required: true
  attr :published_threads, :list, required: true
  attr :drafts, :list, required: true
  attr :current_user, :any, required: true
  attr :diff_style, :string, required: true

  def packet(assigns) do
    ~H"""
    <section
      id="review-packet"
      class="review-packet"
      aria-labelledby="review-packet-title"
    >
      <div class="review-packet-grid">
        <section
          :if={ReviewNavigation.packet_rows(@packet, "invariants") != []}
          class="review-packet-section"
        >
          <h3 class="review-packet-section-title">What must stay true</h3>
          <div class="review-packet-point-list">
            <article
              :for={{body, idx} <- packet_indexed_invariant_points(@packet)}
              class="review-packet-point"
            >
              <span class="review-packet-point-index">{idx + 1}</span>
              <.markdown body={body} class="review-packet-point-body" />
            </article>
          </div>
        </section>

        <section
          :if={ReviewNavigation.packet_rows(@packet, "tour") != []}
          class="review-packet-section"
        >
          <h3 class="review-packet-section-title">Tour</h3>
          <div class="review-packet-row-list">
            <.packet_row
              :for={{row, idx} <- packet_indexed_rows(@packet, "tour")}
              row={row}
              row_id={"packet-tour-#{idx}"}
              file_diffs={@file_diffs}
              selected_patchset={@selected_patchset}
              published_threads={@published_threads}
              drafts={@drafts}
              current_user={@current_user}
              diff_style={@diff_style}
            />
          </div>
        </section>

        <section
          :if={
            ReviewNavigation.packet_text(@packet, "testing_instructions") != "" ||
              ReviewNavigation.packet_rows(@packet, "tasks") != []
          }
          class="review-packet-section"
        >
          <h3 class="review-packet-section-title">Testing</h3>
          <.markdown
            :if={ReviewNavigation.packet_text(@packet, "testing_instructions") != ""}
            body={ReviewNavigation.packet_text(@packet, "testing_instructions")}
            class="review-packet-markdown"
          />
          <ul
            :if={ReviewNavigation.packet_rows(@packet, "tasks") != []}
            class="review-packet-task-list"
          >
            <li
              :for={task <- ReviewNavigation.packet_rows(@packet, "tasks")}
              class="review-packet-task"
            >
              <span class="review-packet-checkbox" aria-hidden="true"></span>
              <span>
                <.inline segments={markdown_inline(ReviewNavigation.packet_text(task, "description"))} />
              </span>
            </li>
          </ul>
        </section>

        <section
          :if={ReviewNavigation.packet_rows(@packet, "rollout") != []}
          class="review-packet-section"
        >
          <h3 class="review-packet-section-title">Rollout</h3>
          <div class="review-packet-row-list">
            <.packet_row
              :for={{row, idx} <- packet_indexed_rows(@packet, "rollout")}
              row={row}
              row_id={"packet-rollout-#{idx}"}
              file_diffs={@file_diffs}
              selected_patchset={@selected_patchset}
              published_threads={@published_threads}
              drafts={@drafts}
              current_user={@current_user}
              diff_style={@diff_style}
            />
          </div>
        </section>

        <section
          :if={ReviewNavigation.packet_rows(@packet, "open_questions") != []}
          class="review-packet-section review-packet-section-wide"
        >
          <h3 class="review-packet-section-title">Open Questions</h3>
          <ul class="review-packet-question-list">
            <li
              :for={question <- ReviewNavigation.packet_rows(@packet, "open_questions")}
              class="review-packet-question"
            >
              <span class="review-packet-question-key">
                {ReviewNavigation.packet_text(question, "key")}
              </span>
              <span>
                <.inline segments={markdown_inline(ReviewNavigation.packet_text(question, "body"))} />
              </span>
            </li>
          </ul>
        </section>
      </div>
    </section>
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
      |> assign(:kind, ReviewNavigation.packet_text(row, "kind"))
      |> assign(:body, ReviewNavigation.packet_text(row, "body"))
      |> assign(:path, ReviewNavigation.packet_text(row, "path"))
      |> assign(:file, file_for(assigns.file_diffs, ReviewNavigation.packet_text(row, "path")))

    ~H"""
    <%= cond do %>
      <% @kind == "hunk" && @file -> %>
        <div class="review-packet-inline-diff">
          <div
            id={"#{@row_id}-diff"}
            phx-hook="DiffRenderer"
            phx-update="ignore"
            data-file-id={"packet-#{@file.id}"}
            data-file-path={@file.path}
            data-file-status={@file.status}
            data-side="new"
            data-patchset-number={@selected_patchset && @selected_patchset.number}
            data-raw-diff={@file.raw_diff}
            data-threads={threads_json(@published_threads, @file.path)}
            data-drafts={drafts_json(@drafts, @file.path, @current_user)}
            data-signed-in={if @current_user, do: "true", else: "false"}
            data-diff-style={@diff_style}
          >
          </div>
        </div>
      <% @kind == "hunk" -> %>
        <span class="review-packet-hunk is-unresolved" translate="no">
          <.icon name="hero-code-bracket-square" class="size-4" />
          {@path}
        </span>
      <% true -> %>
        <.markdown body={@body} class="review-packet-markdown" />
    <% end %>
    """
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

  defp packet_indexed_rows(packet, key) do
    packet
    |> ReviewNavigation.packet_rows(key)
    |> Enum.with_index()
  end

  defp packet_indexed_invariant_points(packet) do
    packet
    |> ReviewNavigation.packet_rows("invariants")
    |> Enum.flat_map(&packet_invariant_point_bodies/1)
    |> Enum.with_index()
  end

  defp packet_invariant_point_bodies(row) do
    body = ReviewNavigation.packet_text(row, "body")

    points =
      body
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&String.starts_with?(&1, "- "))
      |> Enum.map(&String.replace_prefix(&1, "- ", ""))
      |> Enum.reject(&(&1 == ""))

    cond do
      points != [] -> points
      body != "" -> [body]
      true -> []
    end
  end

  defp file_for(file_diffs, file_path) do
    Enum.find(file_diffs, fn fd -> fd.path == file_path end)
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

  defp threads_json(threads, file_path) do
    snapshot = %{published_threads: threads}
    Jason.encode!(ReviewView.thread_payloads_for_file(snapshot, file_path))
  end

  defp drafts_json(drafts, file_path, viewer) do
    snapshot = %{drafts: drafts, viewer: viewer}
    Jason.encode!(ReviewView.draft_payloads_for_file(snapshot, file_path))
  end
end
