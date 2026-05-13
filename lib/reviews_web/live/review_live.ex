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

          <div class="review-patchset" id="patchset-selector" aria-label="Patchset">
            <button
              :for={ps <- @patchsets}
              id={"patchset-#{ps.number}"}
              type="button"
              phx-click="select_patchset"
              phx-value-number={ps.number}
              aria-pressed={
                if(@selected_patchset && @selected_patchset.id == ps.id,
                  do: "true",
                  else: "false"
                )
              }
              class={[
                "review-chip focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-1",
                @selected_patchset && @selected_patchset.id == ps.id &&
                  "is-active"
              ]}
            >
              v{ps.number}
            </button>
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
          <header class="review-header">
            <h1 class="review-title" translate="no">{@review.title}</h1>
            <p :if={@review.description || @file_diffs != []} class="review-description">
              {@review.description || review_summary(@file_diffs, @drafts)}
            </p>
          </header>

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

  defp review_summary(file_diffs, drafts) do
    file_count = length(file_diffs)
    draft_count = length(drafts)

    "#{file_count} changed #{plural(file_count, "file")} · #{draft_count} #{plural(draft_count, "draft")}"
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

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
