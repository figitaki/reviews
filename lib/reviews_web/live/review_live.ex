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
        patchsets = ReviewsContext.list_patchsets(review)
        selected = List.last(patchsets) || nil

        socket =
          socket
          |> assign(:page_title, review.title)
          |> assign(:review, review)
          |> assign(:current_user, current_user)
          |> assign(:patchsets, patchsets)
          |> assign(:selected_patchset, selected)
          |> assign(:show_publish_modal, false)
          |> assign(:summary_body, "")
          |> assign(:banner_message, nil)
          |> assign_files_and_threads()

        {:ok, socket}
    end
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_patchset", %{"number" => number}, socket) do
    case Integer.parse(to_string(number)) do
      {n, _} ->
        case Enum.find(socket.assigns.patchsets, &(&1.number == n)) do
          nil ->
            {:noreply, socket}

          patchset ->
            {:noreply,
             socket
             |> assign(:selected_patchset, patchset)
             |> assign_files_and_threads()}
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
             |> assign_files_and_threads()
             |> push_threads_for_all_files()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Could not publish.")}
        end
    end
  end

  @impl true
  def handle_info({:patchset_pushed, number}, socket) do
    review = socket.assigns.review
    patchsets = ReviewsContext.list_patchsets(review)

    {:noreply,
     socket
     |> assign(:patchsets, patchsets)
     |> assign(:banner_message, "Patchset #{number} just pushed.")}
  end

  @impl true
  def handle_info({:thread_published, _thread}, socket) do
    {:noreply,
     socket
     |> assign_files_and_threads()
     |> push_threads_for_all_files()}
  end

  # ---------------------------------------------------------------------------
  # Assigns helpers
  # ---------------------------------------------------------------------------

  defp assign_files_and_threads(socket) do
    review = socket.assigns.review
    selected = socket.assigns.selected_patchset
    current_user = socket.assigns.current_user

    files = if selected, do: ReviewsContext.list_files(selected), else: []
    file_diffs = file_diff_meta(files, selected)
    published_threads = Threads.list_published_threads(review.id)

    drafts =
      case current_user do
        nil -> []
        author -> Threads.list_drafts_for(review, author)
      end

    socket
    |> assign(:files, files)
    |> assign(:file_diffs, file_diffs)
    |> assign(:published_threads, published_threads)
    |> assign(:drafts, drafts)
  end

  defp file_diff_meta(files, selected_patchset) do
    raw = (selected_patchset && selected_patchset.raw_diff) || ""
    parsed = ReviewsContext.parse_diff_files(raw) |> Enum.into(%{}, &{&1.path, &1})

    Enum.map(files, fn file ->
      meta = Map.get(parsed, file.path, %{additions: 0, deletions: 0})
      raw_for_file = ReviewsContext.raw_diff_for_file(selected_patchset, file.path) || ""

      Map.merge(file_to_map(file), %{
        additions: Map.get(meta, :additions, 0),
        deletions: Map.get(meta, :deletions, 0),
        raw_diff: raw_for_file
      })
    end)
  end

  defp file_to_map(file) do
    %{
      id: file.id,
      path: file.path,
      old_path: file.old_path,
      status: file.status
    }
  end

  defp threads_for_file_payload(socket, file_path) do
    threads =
      socket.assigns.published_threads
      |> Enum.filter(&(&1.file_path == file_path))
      |> Enum.map(&thread_to_payload/1)

    drafts =
      socket.assigns.drafts
      |> Enum.filter(&(&1.thread.file_path == file_path))
      |> Enum.map(&draft_to_payload/1)

    %{threads: threads, drafts: drafts}
  end

  defp thread_to_payload(thread) do
    %{
      id: thread.id,
      file_path: thread.file_path,
      side: thread.side,
      anchor: thread.anchor,
      status: thread.status,
      author: user_to_payload(thread.author),
      comments:
        Enum.map(thread.comments || [], fn c ->
          %{id: c.id, body: c.body, author: nil}
        end)
    }
  end

  defp draft_to_payload(%{thread: thread, comment: comment}) do
    %{
      id: comment.id,
      thread_id: thread.id,
      file_path: thread.file_path,
      side: thread.side,
      anchor: thread.anchor,
      body: comment.body
    }
  end

  defp user_to_payload(%{username: username}), do: %{username: username}
  defp user_to_payload(_), do: nil

  defp push_threads_for_file(socket, nil), do: socket

  defp push_threads_for_file(socket, file_path) when is_binary(file_path) do
    socket = assign_files_and_threads(socket)
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
    <div class="px-4 py-3 sm:px-6 lg:px-8">
      <div class="space-y-4">
        <%!-- Top bar --%>
        <header class="sticky top-0 z-10 bg-base-100 border-b py-2 flex items-center gap-3 flex-wrap">
          <div class="flex-1 min-w-0">
            <h1 class="text-lg font-semibold truncate">{@review.title}</h1>
            <p :if={@review.description} class="text-xs text-base-content/70 truncate">
              {@review.description}
            </p>
          </div>

          <div class="flex items-center gap-1" id="patchset-selector">
            <span class="text-xs text-base-content/70">Patchset:</span>
            <button
              :for={ps <- @patchsets}
              id={"patchset-#{ps.number}"}
              type="button"
              phx-click="select_patchset"
              phx-value-number={ps.number}
              class={[
                "px-2 py-1 text-xs rounded border",
                @selected_patchset && @selected_patchset.id == ps.id &&
                  "bg-primary text-primary-content border-primary"
              ]}
            >
              v{ps.number}
            </button>
          </div>

          <.user_menu current_user={@current_user} />

          <button
            id="publish-review-button"
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="open_publish_modal"
            disabled={@drafts == []}
          >
            Publish review ({length(@drafts)} draft{if length(@drafts) != 1, do: "s"})
          </button>
        </header>

        <%!-- Patchset-pushed banner --%>
        <div
          :if={@banner_message}
          id="patchset-banner"
          class="alert alert-info text-sm flex items-center justify-between"
        >
          <span>{@banner_message}</span>
          <button type="button" phx-click="dismiss_banner" class="btn btn-ghost btn-xs">
            dismiss
          </button>
        </div>

        <%!-- Body: sidebar + diff list --%>
        <div class="rev-shell">
          <aside id="file-tree" class="rev-sidebar text-sm">
            <ul class="menu menu-xs bg-base-200 rounded-box w-full">
              <li :for={fd <- @file_diffs}>
                <a href={"#file-#{fd.id}"} class="flex items-center justify-between gap-2">
                  <span class="flex items-center gap-2 min-w-0">
                    <.status_icon status={fd.status} />
                    <span class="truncate font-mono text-xs">{fd.path}</span>
                  </span>
                  <span class="shrink-0 text-xs whitespace-nowrap">
                    <span class="text-success">+{fd.additions}</span>
                    <span class="text-error">-{fd.deletions}</span>
                  </span>
                </a>
              </li>
              <li :if={@file_diffs == []}>
                <span class="text-base-content/60">No files in this patchset.</span>
              </li>
            </ul>
          </aside>

          <section :if={@selected_patchset} id="diff-files" class="space-y-6 min-w-0">
            <article
              :for={fd <- @file_diffs}
              id={"file-#{fd.id}"}
              class="border rounded overflow-hidden"
            >
              <header class="px-3 py-2 border-b text-sm font-mono flex items-center gap-2 bg-base-200">
                <.status_icon status={fd.status} />
                <span class="truncate">{fd.path}</span>
                <span class="ml-auto text-xs">
                  <span class="text-success">+{fd.additions}</span>
                  <span class="text-error">-{fd.deletions}</span>
                </span>
              </header>
              <div
                id={"diff-#{fd.id}"}
                phx-hook="DiffRenderer"
                phx-update="ignore"
                data-file-path={fd.path}
                data-file-status={fd.status}
                data-side="new"
                data-patchset-number={@selected_patchset.number}
                data-raw-diff={fd.raw_diff}
                data-threads={threads_json(@published_threads, fd.path)}
                data-drafts={drafts_json(@drafts, fd.path)}
                data-signed-in={if @current_user, do: "true", else: "false"}
              >
              </div>
            </article>

            <p :if={@file_diffs == []} class="text-sm text-base-content/60">
              No files in this patchset.
            </p>
          </section>
        </div>
      </div>

      <%!-- Publish modal (Daisy) --%>
      <dialog id="publish-modal" class={["modal", @show_publish_modal && "modal-open"]}>
        <div class="modal-box max-w-2xl">
          <h3 class="text-lg font-semibold">Publish review</h3>
          <p class="text-sm text-base-content/70 mt-1">
            {length(@drafts)} draft{if length(@drafts) != 1, do: "s"} will go live for everyone with the link.
          </p>

          <ul id="draft-list" class="my-4 space-y-2 max-h-72 overflow-y-auto">
            <li
              :for={draft <- @drafts}
              id={"draft-#{draft.comment.id}"}
              class="border rounded p-2 text-sm flex gap-2 items-start"
            >
              <div class="flex-1 min-w-0">
                <p class="font-mono text-xs text-base-content/70 truncate">
                  {draft.thread.file_path}<span :if={anchor_line_hint(draft.thread)}>:{anchor_line_hint(draft.thread)}</span>
                </p>
                <p class="mt-1 whitespace-pre-wrap">{draft.comment.body}</p>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="delete_draft"
                phx-value-comment_id={draft.comment.id}
              >
                remove
              </button>
            </li>
            <li :if={@drafts == []} class="text-sm text-base-content/60 italic">
              No drafts yet.
            </li>
          </ul>

          <form phx-change="update_summary">
            <label class="form-control">
              <span class="label-text">Overall review summary (optional)</span>
              <textarea
                id="summary-textarea"
                name="summary"
                rows="3"
                class="textarea textarea-bordered w-full"
                placeholder="Optional summary that ships with the published drafts."
              >{@summary_body}</textarea>
            </label>
          </form>

          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="close_publish_modal">
              Cancel
            </button>
            <button
              type="button"
              class="btn btn-primary"
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
          aria-label="close"
        >
          close
        </button>
      </dialog>
    </div>
    """
  end

  attr :current_user, :any, default: nil

  defp user_menu(%{current_user: nil} = assigns) do
    ~H"""
    <a href="/auth/github" class="btn btn-sm btn-outline gap-2">
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
        class="btn btn-sm btn-ghost gap-2"
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
        class="dropdown-content menu menu-sm bg-base-100 rounded-box z-20 mt-2 w-44 p-2 shadow border border-base-300"
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

  attr :status, :string, required: true

  defp status_icon(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center justify-center size-4 rounded-sm text-[10px] font-bold",
      @status == "added" && "bg-success/20 text-success",
      @status == "modified" && "bg-info/20 text-info",
      @status == "deleted" && "bg-error/20 text-error",
      @status == "renamed" && "bg-warning/20 text-warning"
    ]}>
      {status_letter(@status)}
    </span>
    """
  end

  defp status_letter("added"), do: "A"
  defp status_letter("modified"), do: "M"
  defp status_letter("deleted"), do: "D"
  defp status_letter("renamed"), do: "R"
  defp status_letter(_), do: "?"

  defp anchor_line_hint(%{anchor: %{"line_number_hint" => hint}}), do: hint
  defp anchor_line_hint(_), do: nil

  defp threads_json(threads, file_path) do
    threads
    |> Enum.filter(&(&1.file_path == file_path))
    |> Enum.map(fn t ->
      %{
        id: t.id,
        side: t.side,
        anchor: t.anchor,
        status: t.status,
        author: %{username: (t.author && t.author.username) || nil},
        comments:
          Enum.map(t.comments || [], fn c ->
            %{id: c.id, body: c.body, author: nil}
          end)
      }
    end)
    |> Jason.encode!()
  end

  defp drafts_json(drafts, file_path) do
    drafts
    |> Enum.filter(&(&1.thread.file_path == file_path))
    |> Enum.map(fn %{thread: t, comment: c} ->
      %{
        id: c.id,
        thread_id: t.id,
        side: t.side,
        anchor: t.anchor,
        body: c.body
      }
    end)
    |> Jason.encode!()
  end
end
