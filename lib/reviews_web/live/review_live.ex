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
  alias Reviews.PacketHunkViews
  alias Reviews.PacketSectionDecisions
  alias Reviews.ReviewHunks
  alias Reviews.ReviewNavigation
  alias Reviews.ReviewPacket
  alias Reviews.ReviewView
  alias Reviews.Reviews, as: ReviewsContext
  alias Reviews.Threads
  alias ReviewsWeb.ReviewLive.DiffComponents
  alias ReviewsWeb.ReviewLive.PacketComponents
  alias ReviewsWeb.ReviewLive.RevisionNavComponents

  @section_auto_open_loc_budget 25
  @section_auto_open_min_hunk_loc 6
  @section_auto_open_max_hunk_loc 500

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
              |> assign(:expanded_file_ids, MapSet.new())
              |> assign(:expanded_hunk_ids, MapSet.new())
              |> assign(:expanded_section_ids, MapSet.new())
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
  def handle_params(params, _uri, socket) do
    case parse_optional_patchset(params["patchset"]) do
      {:ok, patchset_number} ->
        case refresh_snapshot(socket, patchset_number: patchset_number) do
          {:ok, socket} ->
            {:noreply, socket}

          {:error, :patchset_not_found} ->
            {:noreply, put_flash(socket, :error, "Patchset not found.")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Patchset not found.")}
    end
  end

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
  def handle_event("set_section_status", %{"section_index" => index, "status" => status}, socket)
      when status in ["approved", "denied", "ignored"] do
    with %{} = user <- socket.assigns.current_user,
         %{} = patchset <- socket.assigns.selected_patchset,
         {section_index, ""} <- Integer.parse(to_string(index)),
         %{} = section <- ReviewPacket.section_at(patchset.packet || %{}, section_index),
         {:ok, _decision} <- put_section_status(socket, patchset, user, section, status) do
      {:noreply,
       socket
       |> refresh_snapshot!()
       |> collapse_packet_section(section_index)}
    else
      nil -> {:noreply, put_flash(socket, :error, "Sign in to review sections.")}
      _ -> {:noreply, put_flash(socket, :error, "Could not update section.")}
    end
  end

  def handle_event("set_section_status", _params, socket), do: {:noreply, socket}

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
      socket
      |> mounted_diff_paths()
      |> Enum.reduce(socket, fn file, acc ->
        push_event(acc, "diff_style_updated:#{file}", %{style: style})
      end)

    {:noreply, socket}
  end

  def handle_event("select_diff_style", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_packet_section", %{"section_index" => section_index}, socket) do
    case parse_int(section_index) do
      index when is_integer(index) ->
        if MapSet.member?(socket.assigns.expanded_section_ids, index) do
          expanded_section_ids = MapSet.delete(socket.assigns.expanded_section_ids, index)

          {:noreply, assign(socket, :expanded_section_ids, expanded_section_ids)}
        else
          expanded_section_ids = MapSet.put(socket.assigns.expanded_section_ids, index)

          {:noreply,
           socket
           |> assign(:expanded_section_ids, expanded_section_ids)
           |> auto_open_section_hunks(index)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_file_diff", %{"file_id" => file_id}, socket) do
    case parse_int(file_id) do
      id when is_integer(id) ->
        expanded_file_ids =
          if MapSet.member?(socket.assigns.expanded_file_ids, id) do
            MapSet.delete(socket.assigns.expanded_file_ids, id)
          else
            MapSet.put(socket.assigns.expanded_file_ids, id)
          end

        {:noreply, assign(socket, :expanded_file_ids, expanded_file_ids)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_hunk_diff", %{"hunk_id" => hunk_id}, socket) do
    expanded_hunk_ids =
      if MapSet.member?(socket.assigns.expanded_hunk_ids, hunk_id) do
        MapSet.delete(socket.assigns.expanded_hunk_ids, hunk_id)
      else
        MapSet.put(socket.assigns.expanded_hunk_ids, hunk_id)
      end

    {:noreply, assign(socket, :expanded_hunk_ids, expanded_hunk_ids)}
  end

  @impl true
  def handle_event("mark_hunk_viewed", params, socket) do
    update_hunk_view(socket, params, :viewed)
  end

  @impl true
  def handle_event("mark_hunk_unviewed", params, socket) do
    update_hunk_view(socket, params, :unviewed)
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

  defp parse_optional_patchset(nil), do: {:ok, nil}

  defp parse_optional_patchset(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

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

          <.decider_stack deciders={@deciders} />

          <.user_menu current_user={@current_user} />
        </:actions>

        <div class="design-main">
          <% packet = @selected_patchset && @selected_patchset.packet %>
          <% has_packet = ReviewPacket.present?(packet) %>
          <% revision_nav = ReviewNavigation.build(@patchsets, @selected_patchset) %>
          <% diff_stats = ReviewNavigation.diff_stats_from_files(@file_diffs) %>
          <% packet_effort =
            if has_packet do
              PacketComponents.packet_effort_for_header(
                packet,
                @file_diffs,
                @hunks_by_path,
                @packet_section_decisions,
                @selected_patchset,
                @patchsets
              )
            end %>

          <header class="review-header">
            <span :if={has_packet} class="review-packet-kicker">Review Packet</span>
            <h1
              id={if(has_packet, do: "review-packet-title", else: "review-title")}
              class={["review-title", has_packet && "is-packet-title"]}
              translate="no"
            >
              {if(has_packet, do: ReviewPacket.text(packet, "title"), else: @review.title)}
            </h1>
            <PacketComponents.markdown
              :if={has_packet && ReviewPacket.text(packet, "summary") != ""}
              body={ReviewPacket.text(packet, "summary")}
              class="review-description review-packet-lede"
            />
            <p
              :if={!has_packet && (@review.description || @file_diffs != [])}
              class="review-description"
            >
              {@review.description || review_summary(@file_diffs, @drafts)}
            </p>
            <div :if={@selected_patchset} class="review-header-meta">
              <span>{diff_stats.files} {plural(diff_stats.files, "file")}</span>
              <span class="review-header-change-stat">
                <PacketComponents.change_stat
                  additions={diff_stats.additions}
                  deletions={diff_stats.deletions}
                />
              </span>
              <span
                :if={has_packet && packet_effort}
                class="review-header-estimate"
                title="Estimated review time"
              >
                <strong>{packet_effort.time}</strong>
                <span :if={@current_user}>({packet_effort.remaining_time} remaining)</span>
              </span>
            </div>
          </header>

          <RevisionNavComponents.revision_nav
            nav={revision_nav}
            review={@review}
            live_action={@live_action}
            selected_patchset={@selected_patchset}
          />

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

          <PacketComponents.packet
            :if={has_packet && @live_action != :changes}
            packet={packet}
            review={@review}
            patchsets={@patchsets}
            section_decisions={@packet_section_decisions}
            file_diffs={@file_diffs}
            hunks_by_path={@hunks_by_path}
            selected_patchset={@selected_patchset}
            published_threads={@published_threads}
            drafts={@drafts}
            current_user={@current_user}
            diff_style={@diff_style}
            expanded_section_ids={@expanded_section_ids}
            expanded_hunk_ids={@expanded_hunk_ids}
          />

          <%!-- Body: sidebar + diff list --%>
          <DiffComponents.diff_shell
            :if={@live_action == :changes || !has_packet}
            file_diffs={@file_diffs}
            open_threads_by_op={@open_threads_by_op}
            selected_patchset={@selected_patchset}
            published_threads={@published_threads}
            drafts={@drafts}
            current_user={@current_user}
            diff_style={@diff_style}
            expanded_file_ids={@expanded_file_ids}
            expanded_hunk_ids={@expanded_hunk_ids}
            hunks_by_path={@hunks_by_path}
          />
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

  attr :deciders, :list, default: []

  defp decider_stack(%{deciders: []} = assigns) do
    ~H"""
    <div id="decider-stack" class="rev-decider-stack is-empty" aria-label="No published reviews yet">
      <span class="rev-decider-empty">No reviews</span>
    </div>
    """
  end

  defp decider_stack(assigns) do
    assigns =
      assigns
      |> assign(:visible_deciders, Enum.take(assigns.deciders, 5))
      |> assign(:overflow_count, max(length(assigns.deciders) - 5, 0))

    ~H"""
    <div id="decider-stack" class="rev-decider-stack" aria-label="Published review decisions">
      <span class="sr-only">Published reviews</span>
      <div
        :for={decider <- @visible_deciders}
        class="rev-decider"
        title={decider_title(decider)}
        aria-label={decider_title(decider)}
      >
        <div class="rev-decider-avatar">
          <img
            :if={decider.author.avatar_url}
            src={decider.author.avatar_url}
            alt=""
            width="28"
            height="28"
            loading="lazy"
          />
          <span :if={!decider.author.avatar_url} aria-hidden="true">
            {user_initials(decider.author.username)}
          </span>
        </div>
        <span class="rev-decider-badge" aria-hidden="true">
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" />
        </span>
      </div>
      <div
        :if={@overflow_count > 0}
        class="rev-decider rev-decider-more"
        title={"#{@overflow_count} more published reviews"}
        aria-label={"#{@overflow_count} more published reviews"}
      >
        +{@overflow_count}
      </div>
    </div>
    """
  end

  defp user_menu(%{current_user: nil} = assigns) do
    ~H"""
    <a href="/auth/github" class="review-button review-button-secondary">
      Sign in
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

  defp decider_title(%{
         author: author,
         decision: decision,
         comment_count: count,
         summary: summary
       }) do
    base = "#{author.username}: #{decision_label(decision)}"

    details =
      cond do
        is_binary(summary) && String.trim(summary) != "" -> summary
        count == 1 -> "1 comment"
        count > 1 -> "#{count} comments"
        true -> nil
      end

    if details, do: base <> " · " <> details, else: base
  end

  defp decision_label("reviewed"), do: "reviewed"
  defp decision_label(decision), do: decision

  defp user_initials(username) when is_binary(username) do
    username
    |> String.trim()
    |> String.slice(0, 2)
    |> String.upcase()
  end

  defp user_initials(_), do: "?"

  defp collapse_packet_section(socket, section_index) do
    expanded_section_ids =
      socket.assigns[:expanded_section_ids]
      |> Kernel.||(MapSet.new())
      |> MapSet.delete(section_index)

    assign(socket, :expanded_section_ids, expanded_section_ids)
  end

  defp auto_open_section_hunks(socket, section_index) do
    with %{} = patchset <- socket.assigns.selected_patchset,
         %{} = section <- ReviewPacket.section_at(patchset.packet || %{}, section_index) do
      section.rows
      |> Enum.with_index()
      |> Enum.flat_map(&section_preview_hunk(socket.assigns.hunks_by_path, section_index, &1))
      |> open_preview_hunks(socket)
    else
      _ -> socket
    end
  end

  defp auto_open_next_hunks(socket, attrs) do
    candidates =
      case next_section_hunks(socket, attrs) do
        [] -> next_review_hunks(socket, attrs)
        hunks -> hunks
      end

    open_preview_hunks(candidates, socket)
  end

  defp next_section_hunks(socket, %{section_index: section_index} = attrs)
       when is_integer(section_index) do
    with %{} = patchset <- socket.assigns.selected_patchset,
         %{} = section <- ReviewPacket.section_at(patchset.packet || %{}, section_index) do
      section.rows
      |> Enum.with_index()
      |> Enum.flat_map(&section_preview_hunk(socket.assigns.hunks_by_path, section_index, &1))
      |> hunks_after(attrs)
    else
      _ -> []
    end
  end

  defp next_section_hunks(_socket, _attrs), do: []

  defp next_review_hunks(socket, attrs) do
    socket.assigns.file_diffs
    |> Enum.flat_map(fn file -> Map.get(socket.assigns.hunks_by_path, file.path, []) end)
    |> hunks_after(attrs)
  end

  defp hunks_after(hunks, attrs) do
    case Enum.find_index(hunks, &hunk_matches_attrs?(&1, attrs)) do
      index when is_integer(index) -> Enum.drop(hunks, index + 1)
      _ -> []
    end
  end

  defp hunk_matches_attrs?(hunk, attrs) do
    hunk.file_path == attrs.file_path &&
      hunk.row_ref == attrs.row_ref &&
      hunk.hunk_fingerprint == attrs.hunk_fingerprint &&
      hunk.line_start == attrs.line_start &&
      hunk.line_end == attrs.line_end
  end

  defp open_preview_hunks(hunks, socket) do
    hunk_ids =
      hunks
      |> Enum.reject(& &1.viewed?)
      |> Enum.reject(&(hunk_display_loc(&1) > @section_auto_open_max_hunk_loc))
      |> Enum.reduce_while({[], 0}, fn hunk, {ids, spent} ->
        cost = hunk_preview_cost(hunk)

        if spent == 0 || spent + cost <= @section_auto_open_loc_budget do
          {:cont, {[hunk.id | ids], spent + cost}}
        else
          {:halt, {ids, spent}}
        end
      end)
      |> elem(0)

    assign(
      socket,
      :expanded_hunk_ids,
      MapSet.union(socket.assigns.expanded_hunk_ids, MapSet.new(hunk_ids))
    )
  end

  defp section_preview_hunk(hunks_by_path, section_index, {row, row_index}) do
    if ReviewPacket.text(row, "kind") == "hunk" do
      case ReviewHunks.for_packet_row(hunks_by_path, row) do
        nil ->
          []

        hunk ->
          [
            %{
              hunk
              | id: PacketComponents.packet_hunk_id(packet_row_id(section_index, row_index), hunk)
            }
          ]
      end
    else
      []
    end
  end

  defp packet_row_id(section_index, row_index),
    do: "packet-section-#{section_index}-row-#{row_index}"

  defp hunk_preview_cost(hunk) do
    hunk
    |> hunk_display_loc()
    |> max(@section_auto_open_min_hunk_loc)
  end

  defp hunk_display_loc(hunk) do
    hunk
    |> Map.get(:display_raw_diff, "")
    |> to_string()
    |> String.split("\n")
    |> Enum.count(fn line ->
      !String.starts_with?(line, ["diff --git", "index ", "--- ", "+++ ", "@@ "]) &&
        String.trim(line) != ""
    end)
  end

  defp update_hunk_view(socket, _params, _action) when is_nil(socket.assigns.current_user) do
    {:noreply, put_flash(socket, :error, "Sign in to mark hunks viewed.")}
  end

  defp update_hunk_view(socket, params, action) do
    with {:ok, attrs} <- hunk_attrs_from_params(params),
         %{} = patchset <- socket.assigns.selected_patchset,
         %{} = user <- socket.assigns.current_user,
         {:ok, _} <- persist_hunk_view(socket, patchset, user, attrs, action) do
      socket = refresh_snapshot!(socket)

      socket =
        case action do
          :viewed ->
            socket
            |> collapse_hunk(attrs)
            |> auto_open_next_hunks(attrs)

          :unviewed ->
            expand_hunk(socket, attrs)
        end

      {:noreply, socket}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not update hunk.")}
    end
  end

  defp persist_hunk_view(socket, patchset, user, attrs, :viewed) do
    PacketHunkViews.mark_viewed(socket.assigns.review, patchset, user, attrs)
  end

  defp persist_hunk_view(socket, _patchset, user, attrs, :unviewed) do
    PacketHunkViews.clear_viewed(socket.assigns.review, user, attrs)
  end

  defp collapse_hunk(socket, attrs) do
    hunk_id = hunk_id_for_attrs(socket, attrs)

    if hunk_id do
      assign(socket, :expanded_hunk_ids, MapSet.delete(socket.assigns.expanded_hunk_ids, hunk_id))
    else
      socket
    end
  end

  defp expand_hunk(socket, attrs) do
    hunk_id = hunk_id_for_attrs(socket, attrs)

    if hunk_id do
      assign(socket, :expanded_hunk_ids, MapSet.put(socket.assigns.expanded_hunk_ids, hunk_id))
    else
      socket
    end
  end

  defp hunk_id_for_attrs(_socket, %{hunk_id: hunk_id})
       when is_binary(hunk_id) and hunk_id != "" do
    hunk_id
  end

  defp hunk_id_for_attrs(socket, attrs) do
    socket.assigns.hunks_by_path
    |> Map.get(attrs.file_path, [])
    |> Enum.find_value(fn hunk ->
      if hunk_matches_attrs?(hunk, attrs), do: hunk.id
    end)
  end

  defp hunk_attrs_from_params(params) do
    with file_path when is_binary(file_path) and file_path != "" <- params["file_path"],
         row_ref when is_binary(row_ref) and row_ref != "" <- params["row_ref"],
         fingerprint when is_binary(fingerprint) and fingerprint != "" <-
           params["hunk_fingerprint"],
         hunk_index when is_integer(hunk_index) <- parse_int(params["hunk_index"]) do
      {:ok,
       %{
         file_path: file_path,
         row_ref: row_ref,
         hunk_fingerprint: fingerprint,
         hunk_id: blank_to_nil(params["hunk_id"]),
         hunk_index: hunk_index,
         line_start: parse_int(params["line_start"]),
         line_end: parse_int(params["line_end"]),
         section_index: parse_int(params["section_index"]),
         section_title: blank_to_nil(params["section_title"])
       }}
    else
      _ -> :error
    end
  end

  defp blank_to_nil(value) when value in ["", nil], do: nil
  defp blank_to_nil(value), do: value

  defp anchor_line_hint(%{anchor: %{"line_number_hint" => hint}}), do: hint
  defp anchor_line_hint(_), do: nil

  defp assign_snapshot(socket, snapshot) do
    previous_patchset_id =
      socket.assigns[:selected_patchset] && socket.assigns.selected_patchset.id

    next_patchset_id = snapshot.selected_patchset && snapshot.selected_patchset.id

    expanded_file_ids =
      if previous_patchset_id == next_patchset_id do
        socket.assigns[:expanded_file_ids] || MapSet.new()
      else
        MapSet.new()
      end

    expanded_hunk_ids =
      if previous_patchset_id == next_patchset_id do
        socket.assigns[:expanded_hunk_ids] || MapSet.new()
      else
        MapSet.new()
      end

    expanded_section_ids =
      if previous_patchset_id == next_patchset_id do
        socket.assigns[:expanded_section_ids] || MapSet.new()
      else
        MapSet.new()
      end

    socket
    |> assign(:review_snapshot, snapshot)
    |> assign(:review, snapshot.review)
    |> assign(:patchsets, snapshot.patchsets)
    |> assign(:selected_patchset, snapshot.selected_patchset)
    |> assign(:files, snapshot.files)
    |> assign(:file_diffs, snapshot.file_diffs)
    |> assign(:hunks_by_path, snapshot.hunks_by_path)
    |> assign(:packet_hunk_views, snapshot.packet_hunk_views)
    |> assign(:expanded_file_ids, expanded_file_ids)
    |> assign(:expanded_hunk_ids, expanded_hunk_ids)
    |> assign(:expanded_section_ids, expanded_section_ids)
    |> assign(:packet_section_decisions, snapshot.packet_section_decisions)
    |> assign(:published_threads, snapshot.published_threads)
    |> assign(:deciders, snapshot.deciders)
    |> assign(:drafts, snapshot.drafts)
    |> assign(:open_threads_by_op, ReviewView.open_threads_by_op(snapshot))
  end

  defp mounted_diff_paths(socket) do
    changes_paths =
      socket.assigns.hunks_by_path
      |> Enum.flat_map(fn {path, hunks} ->
        if Enum.any?(hunks, &MapSet.member?(socket.assigns.expanded_hunk_ids, &1.id)) do
          [path]
        else
          []
        end
      end)

    packet_paths =
      socket.assigns.expanded_hunk_ids
      |> Enum.flat_map(fn hunk_id ->
        socket.assigns.hunks_by_path
        |> Enum.find_value([], fn {path, hunks} ->
          if Enum.any?(hunks, &hunk_id_matches?(hunk_id, &1.id)), do: [path], else: nil
        end)
      end)

    Enum.uniq(changes_paths ++ packet_paths)
  end

  defp hunk_id_matches?(expanded_id, hunk_id) do
    expanded_id == hunk_id || String.ends_with?(expanded_id, "--#{hunk_id}")
  end

  defp put_section_status(socket, patchset, user, section, status) do
    state =
      PacketSectionDecisions.section_state(
        section,
        socket.assigns.packet_section_decisions,
        patchset,
        socket.assigns.patchsets
      )

    cond do
      state.current && state.current.status == status ->
        PacketSectionDecisions.clear_status(socket.assigns.review, patchset, user, section.index)

      is_nil(state.current) && state.inherited && state.inherited.status == status ->
        PacketSectionDecisions.set_status(socket.assigns.review, patchset, user, %{
          section_index: section.index,
          section_title: section.title,
          section_fingerprint: section.fingerprint,
          section_refs: section.refs,
          status: "pending"
        })

      true ->
        PacketSectionDecisions.set_status(socket.assigns.review, patchset, user, %{
          section_index: section.index,
          section_title: section.title,
          section_fingerprint: section.fingerprint,
          section_refs: section.refs,
          status: status
        })
    end
  end
end
