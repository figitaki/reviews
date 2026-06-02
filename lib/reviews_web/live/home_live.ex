defmodule ReviewsWeb.HomeLive do
  @moduledoc """
  Public landing page for Reviews.

  Above the fold: a centered hero with the install snippet. Below the fold:
  four numbered chapters (Push / Review / Re-prompt / Approve) sit alongside a
  sticky packet preview. Each chapter has an explicit CTA that pushes
  `set_demo_step` to this LiveView, so the reader controls the simulation
  instead of having it follow scroll position. CSS handles the actual
  transitions, including staggered "comment → deny → approve" sequencing
  inside the `:review` step via `transition-delay`.
  """
  use ReviewsWeb, :live_view

  @install_command "curl -fsSL https://raw.githubusercontent.com/figitaki/reviews/main/install.sh | sh"
  @repo_url "https://github.com/figitaki/reviews"

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Reviews — code review for agentic diffs")
     |> assign(:demo_step, :intro)
     |> assign(:install_command, @install_command)
     |> assign(:repo_url, @repo_url)
     |> assign(:current_user, load_current_user(session))}
  end

  defp load_current_user(session) do
    case session["current_user_id"] do
      nil ->
        nil

      id when is_integer(id) ->
        try do
          Reviews.Accounts.get_user!(id)
        rescue
          Ecto.NoResultsError -> nil
        end

      _ ->
        nil
    end
  end

  @impl true
  def handle_event("set_demo_step", %{"step" => step}, socket) do
    case parse_step(step) do
      {:ok, new_step} when new_step != socket.assigns.demo_step ->
        {:noreply, assign(socket, :demo_step, new_step)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("set_demo_step", _params, socket), do: {:noreply, socket}

  def handle_event("send_reprompt", _params, socket) do
    Process.send_after(self(), :complete_reprompt, 1000)
    {:noreply, assign(socket, :demo_step, :reprompting)}
  end

  @impl true
  def handle_info(:complete_reprompt, %{assigns: %{demo_step: :reprompting}} = socket) do
    {:noreply, assign(socket, :demo_step, :reprompt)}
  end

  def handle_info(:complete_reprompt, socket), do: {:noreply, socket}

  # Explicit string → atom whitelist. `String.to_existing_atom/1` is unsafe
  # here because `:review` and `:reprompt` aren't referenced anywhere else
  # in compiled code as literal atoms.
  defp parse_step("push"), do: {:ok, :push}
  defp parse_step("review"), do: {:ok, :review}
  defp parse_step("reprompt"), do: {:ok, :reprompt_prompt}
  defp parse_step("final"), do: {:ok, :final}
  defp parse_step(_), do: :error

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} chrome={false}>
      <main id="reviews-home" class="l-page">
        <Layouts.landing_topbar current_user={@current_user} />

        <section class="home-hero">
          <div class="home-hero-inner">
            <div class="l-eyebrow">Reviews · Code review for agentic diffs</div>
            <h1>Review any diff.</h1>
            <p class="home-hero-lede">
              Turn any diff into a <strong>structured review packet</strong>, optimized for agentic workflows. Install the CLI and skills to start iterating immediately.
            </p>

            <div class="home-hero-install">
              <.install_snippet id="hero-install" command={@install_command} />
            </div>
          </div>
        </section>

        <section class="home-flow">
          <div class="home-flow-prose">
            <.chapter
              num="01"
              label="Push"
              sentinel_step="push"
              cta_label="View section"
              active={@demo_step == :push}
            >
              <h2>A <span class="accent-add">packet</span>, not a wall of edits.</h2>
              <p>
                Every line of the diff sits inside an authored section. The CLI refuses to push otherwise.
              </p>
            </.chapter>

            <.chapter
              num="02"
              label="Review"
              sentinel_step="review"
              cta_label="Request changes"
              active={@demo_step == :review}
            >
              <h2>Decide section by section.</h2>
              <p>Drop a comment, deny what needs work, approve what doesn't. Inline, in place.</p>
            </.chapter>

            <.chapter
              num="03"
              label="Re-prompt"
              sentinel_step="reprompt"
              cta_label="Reprompt"
              active={@demo_step in [:reprompt_prompt, :reprompting, :reprompt]}
            >
              <h2>Hand it back as a re-prompt.</h2>
              <p>
                Ask the agent to fix the denied section, then push the next patchset back into the same review.
              </p>
              <div
                :if={@demo_step in [:reprompt_prompt, :reprompting, :reprompt]}
                class={["home-agent-harness", "is-#{@demo_step}"]}
                role="status"
                aria-live="polite"
              >
                <div class="home-agent-composer">
                  <textarea readonly class="home-agent-input" aria-label="Agent prompt">Address the comments on the review packet</textarea>
                  <button
                    type="button"
                    class="home-agent-send"
                    phx-click="send_reprompt"
                    disabled={@demo_step != :reprompt_prompt}
                  >
                    Send
                  </button>
                </div>
                <div class="home-agent-bubble">Address the comments on the review packet</div>
                <div :if={@demo_step == :reprompting} class="home-agent-status">
                  <span class="home-agent-spinner" aria-hidden="true"></span>
                  <span>Thinking...</span>
                </div>
                <div :if={@demo_step == :reprompt} class="home-agent-status is-done">
                  Pushed a new revision.
                </div>
              </div>
            </.chapter>

            <.chapter
              num="04"
              label="Approve"
              sentinel_step="final"
              cta_label="Approve"
              active={@demo_step == :final}
            >
              <h2>Approve the new revision.</h2>
              <p>
                The denied section is resolved, approvals carry forward, and the packet lands clean.
              </p>
            </.chapter>
          </div>

          <aside class="home-flow-rail">
            <.demo step={@demo_step} />
          </aside>
        </section>

        <.footer repo_url={@repo_url} />
      </main>
    </Layouts.app>
    """
  end

  # ----- partials --------------------------------------------------------

  attr :id, :string, required: true
  attr :command, :string, required: true

  defp install_snippet(assigns) do
    ~H"""
    <div class="l-install" id={"#{@id}-root"} phx-hook="InstallCopy" data-install-command={@command}>
      <span class="l-install-prompt">$</span>
      <div class="l-install-cmd" data-install-cmd>{@command}</div>
      <button type="button" class="l-install-copy" data-install-copy aria-label="Copy install command">
        Copy
      </button>
    </div>
    """
  end

  attr :num, :string, required: true
  attr :label, :string, required: true
  attr :sentinel_step, :string, required: true
  attr :cta_label, :string, required: true
  attr :active, :boolean, default: false
  slot :inner_block, required: true

  defp chapter(assigns) do
    ~H"""
    <article class={["home-chapter", @active && "is-active"]} id={"chapter-#{@sentinel_step}"}>
      <div class="home-chapter-num">
        <span class="pad">00</span>{@num} / {@label}
      </div>
      {render_slot(@inner_block)}
      <button
        type="button"
        class={["home-chapter-cta", @active && "is-active"]}
        phx-click="set_demo_step"
        phx-value-step={@sentinel_step}
        aria-controls="home-demo"
        aria-pressed={@active}
      >
        {@cta_label}
      </button>
    </article>
    """
  end

  attr :step, :atom, required: true

  defp demo(assigns) do
    assigns =
      assigns
      |> assign(:active_section_key, active_demo_section(assigns.step))
      |> assign(:section_one_state, section_state(assigns.step, :section_1))
      |> assign(:section_two_state, section_state(assigns.step, :section_2))

    ~H"""
    <div class="home-demo" data-step={@step} id="home-demo">
      <div class="home-demo-frame">
        <div class="home-demo-titlebar">
          <span class="dots"><i></i><i></i><i></i></span>
          <span class="home-demo-path">
            figitaki<span class="slash">/</span>reviews<span class="slash">/</span>structured-markdown-packets
          </span>
          <span class="home-demo-rev">
            <span class="pip" aria-hidden="true"></span>
            <span>{if revised_step?(@step), do: "v2", else: "v1"}</span>
          </span>
        </div>

        <div class="home-demo-body">
          <div class="home-demo-guide-layout">
            <nav class="home-demo-edge-rail" aria-label="Demo guide rail">
              <span class="review-edge-rail-menu home-demo-menu" aria-hidden="true">
                <.icon name="hero-bars-3" class="size-4" />
              </span>

              <div class="review-edge-rail-ticks">
                <span class={[
                  "review-edge-tick",
                  "home-demo-edge-tick",
                  "is-overview",
                  is_nil(@active_section_key) && "is-active"
                ]}>
                  ★
                </span>
                <span class={[
                  "review-edge-tick",
                  "home-demo-edge-tick",
                  "is-section-1",
                  @active_section_key == :section_1 && "is-active",
                  "is-#{@section_one_state}"
                ]}>
                  01
                </span>
                <span class={[
                  "review-edge-tick",
                  "home-demo-edge-tick",
                  "is-section-2",
                  @active_section_key == :section_2 && "is-active",
                  "is-#{@section_two_state}"
                ]}>
                  02
                </span>
                <span class="review-edge-tick home-demo-edge-tick is-section-3 is-pending">03</span>
              </div>
            </nav>

            <section class={[
              "home-demo-focus-panel",
              is_nil(@active_section_key) && "is-overview",
              @active_section_key == :section_1 && "is-section-1",
              @active_section_key == :section_2 && "is-section-2"
            ]}>
              <div :if={is_nil(@active_section_key)} class="review-guide-panel-inner is-overview">
                <span class="review-guide-eyebrow">Overview · 3 sections · ~2 hr</span>
                <h2 class="review-guide-panel-title">Structured Markdown review packets</h2>
                <p class="review-guide-panel-prose">
                  The packet opens on a focused guide: the rail gives reviewers a map, the panel explains the reasoning behind the changeset, and file rows point straight into the diff.
                </p>
                <div class="review-guide-overview-stats">
                  <span>32 files</span>
                  <span class="r-change-stat num is-v1">
                    <span class="add">+3754</span><span class="del">−191</span>
                  </span>
                  <span class="r-change-stat num is-v2">
                    <span class="add">+412</span><span class="del">−47</span>
                  </span>
                  <span>{if revised_step?(@step), do: "~14 min", else: "~2 hr"}</span>
                </div>
                <span class="review-guide-begin">Begin review <span aria-hidden="true">→</span></span>
              </div>

              <div :if={@active_section_key == :section_1} class="review-guide-panel-inner">
                <span class="review-guide-eyebrow">Section 01 / 03</span>
                <h2 class="review-guide-panel-title">Canonical packet storage and API shape</h2>
                <p class="review-guide-panel-prose">
                  The first section leads with why the packet schema exists: every hunk belongs to authored reviewer context, so review state, reprompts, and revisions can all reason over the same durable section boundary.
                </p>
                <div class="review-guide-panel-meta">
                  <span>Deep</span>
                  <span>3 files</span>
                  <span class="r-change-stat">
                    <span class="add">+286</span><span class="del">−17</span>
                  </span>
                  <span>~13 min</span>
                </div>
                <div class="review-guide-section-controls">
                  <%= case @section_one_state do %>
                    <% :approved -> %>
                      <span class="r-action is-approved">
                        <.icon name="hero-check" class="r-icon" />
                        <span>Approved</span>
                      </span>
                    <% :denied -> %>
                      <span class="r-action is-denied">
                        <.icon name="hero-x-mark" class="r-icon" />
                        <span>Denied</span>
                      </span>
                    <% _ -> %>
                      <span class="r-state-pill kind-approve">
                        <.icon name="hero-check" class="r-icon-sm" />
                      </span>
                      <span class="r-state-pill kind-deny">
                        <.icon name="hero-x-mark" class="r-icon-sm" />
                      </span>
                      <span class="r-state-pill kind-ignore">
                        <.icon name="hero-minus" class="r-icon-sm" />
                      </span>
                  <% end %>
                </div>
                <div class="review-guide-panel-files">
                  <div class="review-guide-files-label">
                    <span>Files</span>
                    <span></span>
                  </div>
                  <.demo_file_row
                    basename="packets.ex"
                    directory="lib/reviews"
                    additions="+18"
                    deletions="−4"
                    state={@section_one_state}
                    label={if(@section_one_state == :approved, do: "Viewed", else: "3 hunks")}
                  />
                  <.demo_file_row
                    basename="packet_json.ex"
                    directory="lib/reviews"
                    additions="+124"
                    deletions="−8"
                    state={@section_one_state}
                    label={if(@section_one_state == :approved, do: "Viewed", else: "5 hunks")}
                  />
                  <.demo_file_row
                    basename="review_live.ex"
                    directory="lib/reviews_web/live"
                    additions="+144"
                    deletions="−5"
                    state={if(@section_one_state == :pending, do: :partial, else: @section_one_state)}
                    label={if(@section_one_state == :pending, do: "1/4 viewed", else: "Viewed")}
                  />
                </div>
              </div>
            </section>

            <div :if={@active_section_key == :section_1} class="home-demo-diff-preview">
              <.demo_diff />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :basename, :string, required: true
  attr :directory, :string, required: true
  attr :additions, :string, required: true
  attr :deletions, :string, required: true
  attr :state, :atom, default: :pending
  attr :label, :string, required: true

  defp demo_file_row(assigns) do
    ~H"""
    <span class={["review-guide-file-row", "is-#{@state}"]}>
      <.icon name="hero-document-text" class="review-guide-file-icon" />
      <span class="review-guide-file-name" translate="no">{@basename}</span>
      <span class="review-guide-file-path" translate="no">{@directory}</span>
      <span class="review-guide-file-stat">
        <span class="r-change-stat">
          <span class="add">{@additions}</span><span class="del">{@deletions}</span>
        </span>
      </span>
      <span class="review-guide-file-state">{@label}</span>
    </span>
    """
  end

  defp demo_diff(assigns) do
    ~H"""
    <div class="home-demo-section-diff r-hunk-card">
      <div class="r-hunk-summary">
        <div class="r-hunk-title">
          <span class="r-status-icon is-modified">M</span>
          <span class="r-hunk-filename">lib/reviews/packets.ex</span>
          <span class="r-hunk-separator">·</span>
          <span class="r-hunk-index">hunk 2 of 4</span>
          <span class="r-hunk-separator">·</span>
          <span class="r-hunk-lines">L 138–156</span>
        </div>
        <div class="r-hunk-meta">
          <span class="r-change-stat">
            <span class="add">+18</span><span class="del">−4</span>
          </span>
        </div>
      </div>
      <div class="r-diff" phx-no-curly-interpolation>
        <div class="r-diff-row is-hunk">
          <span></span><span></span><code>@@ -138,7 +138,12 @@ defp build_packet(patchset) do</code>
        </div>
        <div class="r-diff-row is-context">
          <span>138</span><span>138</span><code> sections = parse_sections(packet)</code>
        </div>
        <div class="r-diff-row is-context">
          <span>139</span><span>139</span><code> hunks    = collect_hunks(patchset)</code>
        </div>
        <div class="r-diff-row is-del">
          <span>140</span><span></span><code>validate!(sections, hunks)</code>
        </div>
        <div class="r-diff-row is-add">
          <span></span><span>140</span><code>case validate(sections, hunks) do</code>
        </div>
        <div class="r-diff-row is-add">
          <span></span><span>141</span><code> :ok                  -&gt; build(sections, hunks)</code>
        </div>
        <div class="r-diff-row is-add">
          <span></span><span>142</span><code> {:error, :missing}   -&gt; reject(:missing_hunks)</code>
        </div>
        <div class="r-diff-row is-add">
          <span></span><span>143</span><code> {:error, :duplicate} -&gt; reject(:duplicate_hunks)</code>
        </div>
        <div class="r-diff-row is-add"><span></span><span>144</span><code>end</code></div>
        <div class="home-demo-comment-row" role="note">
          <div class="home-demo-comment">
            <header class="home-demo-comment-head">
              <span class="home-demo-comment-avatar">M</span>
              <span class="home-demo-comment-author">@maintainer</span>
              <span class="home-demo-comment-on">on packets.ex:142</span>
            </header>
            <p class="home-demo-comment-body">
              What happens when a patchset drops files entirely? <code>:missing</code>
              reads as "needs hunks" — but here it's the opposite case.
            </p>
          </div>
        </div>
        <div class="r-diff-row is-context">
          <span>141</span><span>145</span><code> {:ok, packet}</code>
        </div>
        <div class="r-diff-row is-context"><span>142</span><span>146</span><code>end</code></div>
      </div>
    </div>
    """
  end

  defp footer(assigns) do
    ~H"""
    <footer class="l-footer">
      <div class="l-wrap l-footer-inner">
        <span>© Reviews · open source · MIT</span>
        <span>
          <a href={@repo_url}>github.com/figitaki/reviews</a>
          <a href="#chapter-push">Workflow</a>
        </span>
      </div>
    </footer>
    """
  end

  # ----- state machine ---------------------------------------------------
  # Maps `(step, section)` → the visual state the packet preview should show.
  #
  # Story arc:
  #   :intro    overview panel, all section ticks pending
  #   :push     section 1 panel, section 1 diff preview
  #   :review   reviewer comment appears, section 1 denied, section 2 approved
  #   :reprompt_prompt keeps v1 visible while the prompt composer is open
  #   :reprompting keeps v1 visible while the simulated agent is thinking
  #   :reprompt v2 patchset: section 1 is back to pending, section 2 remains approved
  #   :final    all visible sections are approved.

  defp revised_step?(step), do: step in [:reprompt, :final]

  defp section_state(:intro, _), do: :pending
  defp section_state(:push, _), do: :pending

  defp section_state(step, :section_1) when step in [:review, :reprompt_prompt, :reprompting],
    do: :denied

  defp section_state(step, :section_2) when step in [:review, :reprompt_prompt, :reprompting],
    do: :approved

  defp section_state(:final, _), do: :approved
  defp section_state(_, :section_1), do: :pending
  defp section_state(_, :section_2), do: :approved

  defp active_demo_section(:intro), do: :section_1
  defp active_demo_section(_step), do: :section_1
end
