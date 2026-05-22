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
          <div class="home-demo-eyebrow">Review packet</div>
          <h2 class="home-demo-title">Structured Markdown review packets</h2>

          <div class="home-demo-stats">
            <span>32 files</span>
            <span class="sep">/</span>
            <span class="num is-v1">
              <span class="add">+3754</span> <span class="del">−191</span>
            </span>
            <span class="num is-v2">
              <span class="add">+412</span> <span class="del">−47</span>
            </span>
            <span class="sep">/</span>
            <span>{if revised_step?(@step), do: "~14 min", else: "~2 hr"}</span>
          </div>

          <.demo_section
            id="section-1"
            state={section_state(@step, :section_1)}
            expanded={@step in [:push, :review, :reprompt_prompt, :reprompting]}
            title="Canonical packet storage and API shape"
            effort="Deep"
            effort_class="is-deep"
            add="+286"
            del="−17"
            estimate="~13 min"
            desc="Persisted contract — canonical JSON on patchsets, compact metadata, read-side helpers."
          >
            <:diff>
              <.demo_diff />
            </:diff>
          </.demo_section>

          <.demo_section
            id="section-2"
            state={section_state(@step, :section_2)}
            carried={revised_step?(@step)}
            title="CLI authoring and packet validation"
            effort="Deep"
            effort_class="is-deep"
            add="+734"
            del="−32"
            estimate="~25 min"
            desc="Structured Markdown is parsed, validated for complete hunk coverage, and bundled before push."
          />

          <.demo_section
            id="section-3"
            state={section_state(@step, :section_3)}
            title="Revision navigation and v1/v2 diffing"
            effort="Moderate"
            effort_class="is-moderate"
            add="+184"
            del="−66"
            estimate="~6 min"
            desc="Section-level state carries across patchsets so reviewers don't re-read approved work."
          />
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :effort, :string, required: true
  attr :effort_class, :string, required: true
  attr :add, :string, required: true
  attr :del, :string, required: true
  attr :estimate, :string, required: true
  attr :desc, :string, required: true
  attr :state, :atom, default: :pending
  attr :carried, :boolean, default: false
  attr :expanded, :boolean, default: false
  slot :diff

  defp demo_section(assigns) do
    ~H"""
    <div class={[
      "home-demo-section",
      "is-#{@id}",
      "is-#{@state}",
      @state != :pending && "is-decided",
      @expanded && "is-expanded",
      @carried && "is-carried"
    ]}>
      <div class="home-demo-section-head">
        <div class="home-demo-section-title-row">
          <h3 class="home-demo-section-title">{@title}</h3>
          <span class={["r-effort-pill", @effort_class]}>{@effort}</span>
          <span class="r-change-stat">
            <span class="add">{@add}</span><span class="del">{@del}</span>
          </span>
          <span class="home-demo-section-meta">{@estimate}</span>
        </div>
        <div class="home-demo-section-actions r-section-actions">
          <button
            type="button"
            class="r-state-pill kind-approve"
            aria-label="Approve (demo)"
            tabindex="-1"
          >
            <svg
              class="r-icon-sm"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.4"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M4.5 12.75l6 6 9-13.5"></path>
            </svg>
          </button>
          <button type="button" class="r-state-pill kind-deny" aria-label="Deny (demo)" tabindex="-1">
            <svg
              class="r-icon-sm"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.4"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M6 18L18 6M6 6l12 12"></path>
            </svg>
          </button>
          <button
            type="button"
            class="r-state-pill kind-ignore"
            aria-label="Skip (demo)"
            tabindex="-1"
          >
            <svg
              class="r-icon-sm"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.4"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M5 12h14"></path>
            </svg>
          </button>
          <button
            type="button"
            class="r-action is-approved"
            aria-label="Approved (demo)"
            tabindex="-1"
          >
            <svg
              class="r-icon"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.4"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M4.5 12.75l6 6 9-13.5"></path>
            </svg>
            <span>Approve</span>
          </button>
          <button type="button" class="r-action is-denied" aria-label="Denied (demo)" tabindex="-1">
            <svg
              class="r-icon"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              stroke-width="2.4"
              stroke-linecap="round"
              stroke-linejoin="round"
              aria-hidden="true"
            >
              <path d="M6 18L18 6M6 6l12 12"></path>
            </svg>
            <span>Deny</span>
          </button>
        </div>
      </div>

      <p class="home-demo-section-desc">{@desc}</p>

      <span :if={@carried} class="home-demo-carryover">approved in v1</span>

      <div :if={@diff != []} class="home-demo-section-diff-wrap">
        {render_slot(@diff)}
      </div>
    </div>
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
  #   :intro    all sections pending, section 1 collapsed
  #   :push     all sections pending, section 1 expanded with the diff
  #   :review   reviewer comments on section 1 (CSS reveal at +0ms),
  #             then denies section 1 (+600ms), then approves section 2 (+1200ms)
  #   :reprompt_prompt keeps v1 visible while the prompt composer is open
  #   :reprompting keeps v1 visible while the simulated agent is thinking
  #   :reprompt v2 patchset: section 1 collapses, its deny is gone, section 2
  #             keeps its approval with an "approved in v1" carryover marker
  #   :final    the revised packet is approved.

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

  # Section 3 stays undecided across the whole story — it's there to show the
  # packet has unfinished work, not as a focus.
  defp section_state(_, :section_3), do: :pending
end
