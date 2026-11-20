defmodule ReviewsWeb.ReviewLive.DiffIsland do
  @moduledoc """
  The DiffRenderer hook's element, as a stateful component.

  Its `data-*` attributes carry the file's raw diff and threads, which can be
  hundreds of kilobytes, plus small UI state such as viewed and diff style.
  The cards around it re-derive their assigns on every render, so as a plain
  function component LiveView re-sent the whole raw diff with each reply. A
  live component compares each assign with its previous value, so a reply
  carries only the attributes that changed and the diff goes out once.
  """
  use Phoenix.LiveComponent

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="DiffRenderer"
      phx-update="ignore"
      data-file-id={@file_id}
      data-file-path={@file_path}
      data-context-url={@context_url}
      data-file-status={@file_status}
      data-side="new"
      data-patchset-number={@patchset_number}
      data-raw-diff={@raw_diff}
      data-full-diff={@full_diff}
      data-threads={@threads}
      data-signed-in={@signed_in}
      data-diff-style={@diff_style}
      data-hunk-id={@hunk_id}
      data-hunk-label={@hunk_label}
      data-hunk-details={@hunk_details}
      data-hunk-expanded={@hunk_expanded}
      data-hunk-viewed={@hunk_viewed}
      data-hunk-partially-viewed={@hunk_partially_viewed}
      data-hunk-view-state={@hunk_view_state}
      data-hunk-attrs={@hunk_attrs}
      data-row-ref={@row_ref}
      data-hunk-fingerprint={@hunk_fingerprint}
      data-hunk-index={@hunk_index}
      data-line-start={@line_start}
      data-line-end={@line_end}
      data-section-index={@section_index}
      data-section-title={@section_title}
    >
    </div>
    """
  end
end
