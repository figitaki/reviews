defmodule ReviewsWeb.ReviewLive do
  @moduledoc """
  The review screen — mounted at `/r/:slug`. Anonymous viewing allowed;
  commenting requires a signed-in user (enforced at event-handler time).

  Layout:
    * sticky top bar: title + author + patchset selector + publish button
    * sticky left sidebar: file tree with +/- counts
    * main column: one React island per file, mounted by `DiffRenderer`

  PubSub:
    * subscribes to `"review:<slug>"`
    * receives `{:patchset_pushed, n}` and `{:thread_published, thread}`
  """
  use ReviewsWeb, :live_view

  alias Reviews.Accounts
  alias Reviews.ReviewView
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads

  @impl true
  def mount(%{"slug" => slug}, session, socket) do
    case ReviewsContext.get_review_by_slug(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Review not found.")
         |> push_navigate(to: ~p"/")}

      review ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Reviews.PubSub, "review:#{slug}")
        end

        current_user = load_current_user(session)

        case ReviewView.snapshot(review, current_user) do
          {:ok, snapshot} ->
            socket =
              socket
              |> assign(:page_title, review.title)
              |> assign(:current_user, current_user)
              |> assign(:show_publish_modal, false)
              |> assign(:summary_body, "")
              |> assign(:banner_message, nil)
              |> assign(:diff_style, "split")
              |> assign_snapshot(snapshot)

            {:ok, socket}

          {:error, :patchset_not_found} ->
            {:ok,
             socket
             |> put_flash(:error, "Patchset not found.")
             |> push_navigate(to: ~p"/")}
        end
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_patchset", %{"number" => number}, socket) do
    case Integer.parse(to_string(number)) do
      {n, _} ->
        case refresh_snapshot(socket, patchset_number: n) do
          {:ok, socket} -> {:noreply, socket}
          {:error, :patchset_not_found} -> {:noreply, socket}
        end

      :error ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("open_publish_modal", _params, socket) do
    {:noreply, assign(socket, :show_publish_modal, true)}
  end

  @impl true
  def handle_event("close_publish_modal", _params, socket) do
    {:noreply, assign(socket, :show_publish_modal, false)}
  end

  @impl true
  def handle_event("update_summary", %{"summary" => body}, socket) do
    {:noreply, assign(socket, :summary_body, body)}
  end

  @impl true
  def handle_event("dismiss_banner", _params, socket) do
    {:noreply, assign(socket, :banner_message, nil)}
  end

  @impl true
  def handle_event("select_diff_style", %{"style" => style}, socket)
      when style in ["split", "unified"] do
    socket = assign(socket, :diff_style, style)

    socket =
      Enum.reduce(socket.assigns.files, socket, fn file, acc ->
        push_event(acc, "diff_style_updated:#{file.path}", %{style: style})
      end)

    {:noreply, socket}
  end

  def handle_event("select_diff_style", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("save_draft", params, socket) do
    require Logger

    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, "Sign in to leave a comment.")}

      author ->
        case Threads.save_draft(socket.assigns.review, author, params) do
          {:ok, _} ->
            {:noreply, push_threads_for_file(socket, params["file_path"])}

          {:error, reason} ->
            Logger.warning("save_draft failed: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, "Could not save draft.")}
        end
    end
  end

  @impl true
  def handle_event("delete_draft", %{"comment_id" => comment_id}, socket) do
    case {socket.assigns.current_user, parse_int(comment_id)} do
      {nil, _} ->
        {:noreply, socket}

      {_, nil} ->
        {:noreply, socket}

      {author, id} ->
        _ = Threads.delete_draft(id, author)
        # We don't know which file the draft belonged to without re-querying,
        # so push a refresh to every file in the current patchset.
        {:noreply, push_threads_for_all_files(socket)}
    end
  end

  @impl true
  def handle_event("publish_review", _params, socket) do
    case socket.assigns.current_user do
      nil ->
        {:noreply, put_flash(socket, :error, "Sign in to publish your review.")}

      author ->
        opts = [summary: socket.assigns.summary_body]

        case Threads.publish_all_drafts(socket.assigns.review, author, opts) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:show_publish_modal, false)
             |> assign(:summary_body, "")
             |> put_flash(:info, "Review published.")
             |> refresh_snapshot!()
             |> push_threads_for_all_files()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not publish.")}
        end
    end
  end

  @impl true
  def handle_info({:patchset_pushed, number}, socket) do
    {:noreply,
     socket
     |> refresh_snapshot!()
     |> assign(:banner_message, "Patchset #{number} just pushed.")}
  end

  @impl true
  def handle_info({:thread_published, _thread}, socket) do
    {:noreply,
     socket
     |> refresh_snapshot!()
     |> push_threads_for_all_files()}
  end

  # ---------------------------------------------------------------------------
  # Assigns helpers
  # ---------------------------------------------------------------------------

  defp refresh_snapshot!(socket, opts \\ []) do
    case refresh_snapshot(socket, opts) do
      {:ok, socket} -> socket
      {:error, _reason} -> socket
    end
  end

  defp refresh_snapshot(socket, opts) do
    review = socket.assigns.review
    current_user = socket.assigns.current_user
    selected = socket.assigns.selected_patchset

    patchset_number =
      Keyword.get_lazy(opts, :patchset_number, fn ->
        selected && selected.number
      end)

    case ReviewView.snapshot(review, current_user, patchset_number: patchset_number) do
      {:ok, snapshot} -> {:ok, assign_snapshot(socket, snapshot)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp threads_for_file_payload(socket, file_path) do
    %{
      threads: ReviewView.thread_payloads_for_file(socket.assigns.review_snapshot, file_path),
      drafts: ReviewView.draft_payloads_for_file(socket.assigns.review_snapshot, file_path)
    }
  end

  defp push_threads_for_file(socket, nil), do: socket

  defp push_threads_for_file(socket, file_path) when is_binary(file_path) do
    socket = refresh_snapshot!(socket)
    payload = threads_for_file_payload(socket, file_path)
    push_event(socket, "threads_updated:#{file_path}", payload)
  end

  defp push_threads_for_all_files(socket) do
    Enum.reduce(socket.assigns.files, socket, fn file, acc ->
      payload = threads_for_file_payload(acc, file.path)
      push_event(acc, "threads_updated:#{file.path}", payload)
    end)
  end

  defp parse_int(int) when is_integer(int), do: int

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp load_current_user(session) do
    case session["current_user_id"] do
      nil ->
        nil

      id when is_integer(id) ->
        try do
          Accounts.get_user!(id)
        rescue
          Ecto.NoResultsError -> nil
        end

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />
    <div class="review-page min-h-screen">
      <.ds_shell brand="Reviews" home={~p"/"}>
        <:actions>
          <div
            class="review-diff-style"
            id="diff-style-toggle"
            role="group"
            aria-label="Diff layout"
            phx-hook=".DiffStylePref"
          >
            <button
              id="diff-style-split"
              type="button"
              phx-click="select_diff_style"
              phx-value-style="split"
              aria-pressed={if @diff_style == "split", do: "true", else: "false"}
              aria-label="Split view"
              title="Split view"
              class={["review-chip", @diff_style == "split" && "is-active"]}
            >
              <.icon name="hero-table-cells" class="w-4 h-4" />
            </button>
            <button
              id="diff-style-unified"
              type="button"
              phx-click="select_diff_style"
              phx-value-style="unified"
              aria-pressed={if @diff_style == "unified", do: "true", else: "false"}
              aria-label="Unified view"
              title="Unified view"
              class={["review-chip", @diff_style == "unified" && "is-active"]}
            >
              <.icon name="hero-queue-list" class="w-4 h-4" />
            </button>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".DiffStylePref">
              export default {
                mounted() {
                  const KEY = "reviews:diffStyle"
                  const saved = localStorage.getItem(KEY)
                  if (saved === "split" || saved === "unified") {
                    const currentBtn = this.el.querySelector('[aria-pressed="true"]')
                    const currentStyle = currentBtn?.id === "diff-style-unified" ? "unified" : "split"
                    if (saved !== currentStyle) {
                      this.pushEvent("select_diff_style", { style: saved })
                    }
                  }
                  this.el.addEventListener("click", (e) => {
                    const btn = e.target.closest("[phx-value-style]")
                    if (!btn) return
                    const style = btn.getAttribute("phx-value-style")
                    if (style === "split" || style === "unified") {
                      localStorage.setItem(KEY, style)
                    }
                  })
                }
              }
            </script>
          </div>

          <button
            id="publish-review-button"
            type="button"
            class="review-button review-button-primary"
            phx-click="open_publish_modal"
            disabled={@drafts == []}
          >
            <%= if @drafts == [] do %>
              Publish
            <% else %>
              Publish ({length(@drafts)})
            <% end %>
          </button>

          <.user_menu current_user={@current_user} />
        </:actions>

        <div class="design-main">
          <% packet = @selected_patchset && @selected_patchset.packet %>
          <% has_packet = packet_present?(packet) %>
          <% revision_nav = revision_nav(@patchsets, @selected_patchset) %>

          <header class="review-header">
            <span :if={has_packet} class="review-packet-kicker">Review Packet</span>
            <h1
              id={if(has_packet, do: "review-packet-title", else: "review-title")}
              class={["review-title", has_packet && "is-packet-title"]}
              translate="no"
            >
              {if(has_packet, do: packet_text(packet, "title"), else: @review.title)}
            </h1>
            <.packet_markdown
              :if={has_packet && packet_text(packet, "summary") != ""}
              body={packet_text(packet, "summary")}
              class="review-description review-packet-lede"
            />
            <p
              :if={!has_packet && (@review.description || @file_diffs != [])}
              class="review-description"
            >
              {@review.description || review_summary(@file_diffs, @drafts)}
            </p>
            <div :if={@selected_patchset} class="review-header-meta">
              <span>Round {revision_nav.current_round.index}</span>
              <span>Turn v{@selected_patchset.number}</span>
              <span>{format_diff_stats(diff_stats(@file_diffs))}</span>
            </div>
          </header>

          <.revision_nav nav={revision_nav} selected_patchset={@selected_patchset} />

          <%!-- Patchset-pushed banner --%>
          <div
            :if={@banner_message}
            id="patchset-banner"
            class="review-banner flex items-center justify-between gap-3"
          >
            <span>{@banner_message}</span>
            <button type="button" phx-click="dismiss_banner" class="review-button review-button-ghost">
              Dismiss
            </button>
          </div>

          <section
            :if={has_packet}
            id="review-packet"
            class="review-packet"
            aria-labelledby="review-packet-title"
          >
            <div class="review-packet-grid">
              <section :if={packet_rows(packet, "invariants") != []} class="review-packet-section">
                <h3 class="review-packet-section-title">What must stay true</h3>
                <div class="review-packet-point-list">
                  <article
                    :for={{body, idx} <- packet_indexed_invariant_points(packet)}
                    class="review-packet-point"
                  >
                    <span class="review-packet-point-index">{idx + 1}</span>
                    <.packet_markdown body={body} class="review-packet-point-body" />
                  </article>
                </div>
              </section>

              <section :if={packet_rows(packet, "tour") != []} class="review-packet-section">
                <h3 class="review-packet-section-title">Tour</h3>
                <div class="review-packet-row-list">
                  <.packet_row
                    :for={{row, idx} <- packet_indexed_rows(packet, "tour")}
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
                  packet_text(packet, "testing_instructions") != "" ||
                    packet_rows(packet, "tasks") != []
                }
                class="review-packet-section"
              >
                <h3 class="review-packet-section-title">Testing</h3>
                <.packet_markdown
                  :if={packet_text(packet, "testing_instructions") != ""}
                  body={packet_text(packet, "testing_instructions")}
                  class="review-packet-markdown"
                />
                <ul :if={packet_rows(packet, "tasks") != []} class="review-packet-task-list">
                  <li :for={task <- packet_rows(packet, "tasks")} class="review-packet-task">
                    <span class="review-packet-checkbox" aria-hidden="true"></span>
                    <span>
                      <.packet_inline segments={markdown_inline(packet_text(task, "description"))} />
                    </span>
                  </li>
                </ul>
              </section>

              <section :if={packet_rows(packet, "rollout") != []} class="review-packet-section">
                <h3 class="review-packet-section-title">Rollout</h3>
                <div class="review-packet-row-list">
                  <.packet_row
                    :for={{row, idx} <- packet_indexed_rows(packet, "rollout")}
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
                :if={packet_rows(packet, "open_questions") != []}
                class="review-packet-section review-packet-section-wide"
              >
                <h3 class="review-packet-section-title">Open Questions</h3>
                <ul class="review-packet-question-list">
                  <li
                    :for={question <- packet_rows(packet, "open_questions")}
                    class="review-packet-question"
                  >
                    <span class="review-packet-question-key">
                      {packet_text(question, "key")}
                    </span>
                    <span>
                      <.packet_inline segments={markdown_inline(packet_text(question, "body"))} />
                    </span>
                  </li>
                </ul>
              </section>
            </div>
          </section>

          <%!-- Body: sidebar + diff list --%>
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
        </div>
      </.ds_shell>

      <%!-- Publish modal (Daisy) --%>
      <dialog id="publish-modal" class={["modal", @show_publish_modal && "modal-open"]}>
        <div class="modal-box review-modal max-w-2xl">
          <h3 class="review-modal-title">Publish Review</h3>
          <p class="review-description mt-1">
            {length(@drafts)} draft{if length(@drafts) != 1, do: "s"} will go live for everyone with the link.
          </p>

          <ul id="draft-list" class="my-4 space-y-2 max-h-72 overflow-y-auto">
            <li
              :for={draft <- @drafts}
              id={"draft-#{draft.comment.id}"}
              class="review-draft-item flex gap-2 items-start"
            >
              <div class="flex-1 min-w-0">
                <p class="rev-file-path truncate" translate="no">
                  {draft.thread.file_path}<span :if={anchor_line_hint(draft.thread)}>:{anchor_line_hint(draft.thread)}</span>
                </p>
                <p class="mt-1 whitespace-pre-wrap">{draft.comment.body}</p>
              </div>
              <button
                type="button"
                class="review-button review-button-ghost"
                phx-click="delete_draft"
                phx-value-comment_id={draft.comment.id}
              >
                Remove
              </button>
            </li>
            <li :if={@drafts == []} class="rev-empty">
              No drafts yet.
            </li>
          </ul>

          <form phx-change="update_summary">
            <label class="form-control">
              <span class="review-label mb-2">Overall review summary (optional)</span>
              <textarea
                id="summary-textarea"
                name="summary"
                rows="3"
                class="review-textarea"
                placeholder="Optional summary that ships with the published drafts…"
              >{@summary_body}</textarea>
            </label>
          </form>

          <div class="modal-action">
            <button
              type="button"
              class="review-button review-button-ghost"
              phx-click="close_publish_modal"
            >
              Cancel
            </button>
            <button
              type="button"
              class="review-button review-button-primary"
              phx-click="publish_review"
              disabled={@drafts == []}
            >
              Publish {length(@drafts)} comment{if length(@drafts) != 1, do: "s"}
            </button>
          </div>
        </div>
        <button
          type="button"
          class="modal-backdrop"
          phx-click="close_publish_modal"
          aria-label="Close dialog"
        >
          <span class="sr-only">Close</span>
        </button>
      </dialog>
    </div>
    """
  end

  attr :current_user, :any, default: nil

  defp user_menu(%{current_user: nil} = assigns) do
    ~H"""
    <a href="/auth/github" class="review-button review-button-secondary gap-2">
      <svg
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 16 16"
        class="size-4"
        aria-hidden="true"
        fill="currentColor"
      >
        <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z" />
      </svg>
      Sign in with GitHub
    </a>
    """
  end

  defp user_menu(assigns) do
    ~H"""
    <div class="dropdown dropdown-end">
      <button
        tabindex="0"
        type="button"
        class="review-button review-button-secondary gap-2"
        aria-label={"Account menu for #{@current_user.username}"}
      >
        <img
          :if={@current_user.avatar_url}
          src={@current_user.avatar_url}
          alt=""
          width="24"
          height="24"
          class="size-6 rounded-full"
        />
        <span class="text-sm">{@current_user.username}</span>
      </button>
      <ul
        tabindex="0"
        class="dropdown-content menu menu-sm review-menu z-20 mt-2 w-44 p-2"
      >
        <li>
          <.link navigate={~p"/settings"}>Settings</.link>
        </li>
        <li>
          <.link href={~p"/auth/logout"} method="delete">Sign out</.link>
        </li>
      </ul>
    </div>
    """
  end

  attr :nav, :map, required: true
  attr :selected_patchset, :any, required: true

  defp revision_nav(assigns) do
    ~H"""
    <section
      :if={@selected_patchset && @nav.rounds != []}
      id="revision-nav"
      class="review-revision-nav"
      aria-label="Review rounds and turns"
    >
      <div class="review-round-nav">
        <div class="review-revision-copy">
          <span class="review-revision-label">
            Round {@nav.current_round.index} of {@nav.round_count}
          </span>
          <strong class="review-revision-title">
            {@nav.current_round.title}
          </strong>
        </div>

        <div class="review-revision-controls" aria-label="Round navigation">
          <button
            type="button"
            class="review-nav-button"
            phx-click="select_patchset"
            phx-value-number={@nav.previous_round && @nav.previous_round.start_number}
            disabled={!@nav.previous_round}
            aria-label="Previous round"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Round
          </button>
          <div class="review-round-chip-list" aria-label="Rounds">
            <button
              :for={round <- @nav.rounds}
              type="button"
              class={[
                "review-round-chip",
                round.index == @nav.current_round.index && "is-active"
              ]}
              phx-click="select_patchset"
              phx-value-number={round.start_number}
              aria-pressed={if(round.index == @nav.current_round.index, do: "true", else: "false")}
              title={round.title}
            >
              {round.index}
            </button>
          </div>
          <button
            type="button"
            class="review-nav-button"
            phx-click="select_patchset"
            phx-value-number={@nav.next_round && @nav.next_round.start_number}
            disabled={!@nav.next_round}
            aria-label="Next round"
          >
            Round <.icon name="hero-arrow-right" class="size-4" />
          </button>
        </div>
      </div>

      <div class="review-turn-nav">
        <div class="review-revision-copy">
          <span class="review-revision-label">
            Turn {@nav.selected_turn_index} of {@nav.current_round.turn_count}
          </span>
          <span class="review-turn-range">
            v{@nav.current_round.start_number}
            <%= if @nav.current_round.end_number != @nav.current_round.start_number do %>
              -v{@nav.current_round.end_number}
            <% end %>
          </span>
        </div>

        <div class="review-revision-controls" aria-label="Turn navigation">
          <button
            type="button"
            class="review-nav-button"
            phx-click="select_patchset"
            phx-value-number={@nav.previous_turn && @nav.previous_turn.number}
            disabled={!@nav.previous_turn}
            aria-label="Previous turn"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Turn
          </button>
          <div class="review-turn-chip-list" aria-label="Turns in this round">
            <button
              :for={turn <- @nav.current_round.turns}
              id={"patchset-#{turn.number}"}
              type="button"
              class={[
                "review-turn-chip",
                turn.number == @selected_patchset.number && "is-active",
                turn.packet_present && "has-packet"
              ]}
              phx-click="select_patchset"
              phx-value-number={turn.number}
              aria-pressed={if(turn.number == @selected_patchset.number, do: "true", else: "false")}
              title={
                if(turn.packet_present,
                  do: "v#{turn.number} has a review packet",
                  else: "v#{turn.number}"
                )
              }
            >
              v{turn.number}
            </button>
          </div>
          <button
            type="button"
            class="review-nav-button"
            phx-click="select_patchset"
            phx-value-number={@nav.next_turn && @nav.next_turn.number}
            disabled={!@nav.next_turn}
            aria-label="Next turn"
          >
            Turn <.icon name="hero-arrow-right" class="size-4" />
          </button>
        </div>
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

  defp packet_row(%{row: row} = assigns) do
    assigns =
      assigns
      |> assign(:kind, packet_text(row, "kind"))
      |> assign(:body, packet_text(row, "body"))
      |> assign(:path, packet_text(row, "path"))
      |> assign(:file, file_for(assigns.file_diffs, packet_text(row, "path")))

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
        <.packet_markdown body={@body} class="review-packet-markdown" />
    <% end %>
    """
  end

  attr :body, :string, required: true
  attr :class, :string, default: "review-packet-markdown"

  defp packet_markdown(assigns) do
    assigns = assign(assigns, :blocks, markdown_blocks(assigns.body))

    ~H"""
    <div class={@class}>
      <%= for block <- @blocks do %>
        <h3
          :if={block.kind == :heading && block.level == 3}
          class="review-packet-md-heading is-h3"
        >
          <.packet_inline segments={block.segments} />
        </h3>
        <h4
          :if={block.kind == :heading && block.level == 4}
          class="review-packet-md-heading is-h4"
        >
          <.packet_inline segments={block.segments} />
        </h4>
        <ul :if={block.kind == :list} class="review-packet-md-list">
          <li :for={item <- block.items}>
            <.packet_inline segments={item} />
          </li>
        </ul>
        <p :if={block.kind == :paragraph} class="review-packet-md-paragraph">
          <.packet_inline segments={block.segments} />
        </p>
      <% end %>
    </div>
    """
  end

  attr :segments, :list, required: true

  defp packet_inline(assigns) do
    ~H"""
    <%= for segment <- @segments do %>
      <code :if={segment.kind == :code} class="review-packet-inline-code">{segment.text}</code>
      <span :if={segment.kind == :text}>{segment.text}</span>
    <% end %>
    """
  end

  defp review_summary(file_diffs, drafts) do
    file_count = length(file_diffs)
    draft_count = length(drafts)

    "#{file_count} changed #{plural(file_count, "file")} · #{draft_count} #{plural(draft_count, "draft")}"
  end

  defp diff_stats(file_diffs) do
    Enum.reduce(file_diffs, %{files: 0, additions: 0, deletions: 0}, fn file, acc ->
      %{
        files: acc.files + 1,
        additions: acc.additions + Map.get(file, :additions, 0),
        deletions: acc.deletions + Map.get(file, :deletions, 0)
      }
    end)
  end

  defp format_diff_stats(%{files: files, additions: additions, deletions: deletions}) do
    "#{files} #{plural(files, "file")} · +#{additions} -#{deletions}"
  end

  defp revision_nav(patchsets, selected_patchset) do
    rounds = review_rounds(patchsets)
    selected_number = selected_patchset && selected_patchset.number

    current_round =
      Enum.find(rounds, &Enum.any?(&1.turns, fn t -> t.number == selected_number end))

    current_round = current_round || List.last(rounds) || empty_round()
    current_round_index = Enum.find_index(rounds, &(&1.index == current_round.index)) || 0

    selected_turn_index =
      Enum.find_index(current_round.turns, &(&1.number == selected_number)) || 0

    %{
      rounds: rounds,
      round_count: length(rounds),
      current_round: current_round,
      selected_turn_index: selected_turn_index + 1,
      previous_round: at_index(rounds, current_round_index - 1),
      next_round: Enum.at(rounds, current_round_index + 1),
      previous_turn: at_index(current_round.turns, selected_turn_index - 1),
      next_turn: Enum.at(current_round.turns, selected_turn_index + 1)
    }
  end

  defp review_rounds([]), do: []

  defp review_rounds(patchsets) do
    patchsets
    |> Enum.reduce([], fn patchset, rounds ->
      turn = patchset_turn(patchset)

      cond do
        rounds == [] ->
          [new_round(1, turn, patchset)]

        packet_present?(patchset.packet) ->
          [new_round(length(rounds) + 1, turn, patchset) | rounds]

        true ->
          [round | rest] = rounds

          [
            %{
              round
              | turns: [turn | round.turns],
                end_number: turn.number,
                turn_count: round.turn_count + 1
            }
            | rest
          ]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn round -> %{round | turns: Enum.reverse(round.turns)} end)
  end

  defp patchset_turn(patchset) do
    stats = patchset_stats(patchset)

    %{
      number: patchset.number,
      packet_present: packet_present?(patchset.packet),
      stats: stats
    }
  end

  defp new_round(index, turn, patchset) do
    %{
      index: index,
      title: round_title(patchset, index),
      start_number: turn.number,
      end_number: turn.number,
      turn_count: 1,
      turns: [turn]
    }
  end

  defp empty_round do
    %{index: 1, title: "Round 1", start_number: nil, end_number: nil, turn_count: 0, turns: []}
  end

  defp round_title(patchset, index) do
    case packet_text(patchset.packet, "title") do
      "" -> "Round #{index}"
      title -> title
    end
  end

  defp patchset_stats(%{raw_diff: raw_diff}) do
    raw_diff
    |> ReviewsContext.parse_diff_files()
    |> diff_stats()
  end

  defp at_index(_items, index) when index < 0, do: nil
  defp at_index(items, index), do: Enum.at(items, index)

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp anchor_line_hint(%{anchor: %{"line_number_hint" => hint}}), do: hint
  defp anchor_line_hint(_), do: nil

  defp file_id_for(file_diffs, file_path) do
    Enum.find_value(file_diffs, fn fd -> fd.path == file_path && fd.id end)
  end

  defp file_for(file_diffs, file_path) do
    Enum.find(file_diffs, fn fd -> fd.path == file_path end)
  end

  defp packet_present?(packet) when is_map(packet) do
    packet_text(packet, "title") != "" ||
      packet_text(packet, "summary") != "" ||
      packet_rows(packet, "invariants") != [] ||
      packet_rows(packet, "tour") != [] ||
      packet_text(packet, "testing_instructions") != "" ||
      packet_rows(packet, "tasks") != [] ||
      packet_rows(packet, "rollout") != [] ||
      packet_rows(packet, "open_questions") != []
  end

  defp packet_present?(_), do: false

  defp packet_rows(packet, key) when is_map(packet) do
    case packet_value(packet, key) do
      rows when is_list(rows) -> Enum.filter(rows, &is_map/1)
      _ -> []
    end
  end

  defp packet_rows(_, _), do: []

  defp packet_indexed_rows(packet, key), do: packet_rows(packet, key) |> Enum.with_index()

  defp packet_indexed_invariant_points(packet) do
    packet
    |> packet_rows("invariants")
    |> Enum.flat_map(&packet_invariant_point_bodies/1)
    |> Enum.with_index()
  end

  defp packet_invariant_point_bodies(row) do
    body = packet_text(row, "body")

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

  defp packet_text(packet, key) when is_map(packet) do
    case packet_value(packet, key) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _ -> ""
    end
  end

  defp packet_text(_, _), do: ""

  defp packet_value(packet, key) do
    Map.get(packet, key) || Map.get(packet, String.to_atom(key))
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

  defp assign_snapshot(socket, snapshot) do
    socket
    |> assign(:review_snapshot, snapshot)
    |> assign(:review, snapshot.review)
    |> assign(:patchsets, snapshot.patchsets)
    |> assign(:selected_patchset, snapshot.selected_patchset)
    |> assign(:files, snapshot.files)
    |> assign(:file_diffs, snapshot.file_diffs)
    |> assign(:published_threads, snapshot.published_threads)
    |> assign(:drafts, snapshot.drafts)
    |> assign(:open_threads_by_op, ReviewView.open_threads_by_op(snapshot))
  end
end
