defmodule ReviewsWeb.HomeLive do
  @moduledoc "Public landing page with installation and a link to the real demo review."
  use ReviewsWeb, :live_view

  @install_command "curl -fsSL https://raw.githubusercontent.com/figitaki/reviews/main/install.sh | sh"
  @repo_url "https://github.com/figitaki/reviews"

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Reviews — code review for agentic diffs")
     |> assign(:install_command, @install_command)
     |> assign(:repo_url, @repo_url)
     |> assign(:demo_slug, Reviews.DemoReview.slug())
     |> assign(:current_user, load_current_user(session))}
  end

  defp load_current_user(session) do
    case session["current_user_id"] do
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
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main id="reviews-home" class="l-page">
        <Layouts.landing_topbar current_user={@current_user} show_workflow_anchor={false} />

        <div class="home-content">
          <section class="home-hero" aria-labelledby="home-title">
            <h1 id="home-title">Review any diff.</h1>
            <p class="home-hero-lede">
              A review packet puts the reasoning next to the code. Give reviewers a guide
              through your changes, not just a wall of edits.
            </p>
            <div class="home-actions">
              <.link
                id="home-demo-link"
                navigate={~p"/r/#{@demo_slug}"}
                class="r-button r-button-primary"
              >
                Open demo review
              </.link>
              <a href="#home-install" class="r-button">Install the CLI</a>
            </div>
            <p class="home-demo-note">A real review packet. No sign-in needed to read.</p>
          </section>

          <section id="home-workflow" class="home-workflow" aria-label="How Reviews works">
            <article id="home-packet">
              <h2>Lead with context</h2>
              <p>
                Push a diff and an authored Markdown packet from the CLI. Organize the
                changes into sections, with explanations alongside the relevant hunks.
              </p>
            </article>
            <article id="home-decisions">
              <h2>Review section by section</h2>
              <p>
                Share a link. Reviewers can read the guide, comment on the code, and
                approve, request changes, or skip each section.
              </p>
            </article>
            <article id="home-revisions">
              <h2>Keep the next revision in the same review</h2>
              <p>
                Bring feedback back to your agent and push an updated patchset.
                Decisions carry forward until the section changes.
              </p>
            </article>
          </section>

          <section id="home-install" class="home-install" aria-labelledby="home-install-title">
            <h2 id="home-install-title">Start from your terminal</h2>
            <p>Install the CLI and agent skills, then push your first review packet.</p>
            <div id="hero-install-root" class="home-install-command" phx-hook=".InstallCopy">
              <code data-install-cmd>{@install_command}</code>
              <button
                type="button"
                class="r-button"
                data-install-copy
                aria-label="Copy install command"
              >
                Copy
              </button>
              <span class="home-copy-status" role="status" data-copy-status></span>
            </div>
            <a id="home-docs-link" href={@repo_url <> "#readme"} class="home-docs-link">
              Read the setup guide
            </a>
          </section>
        </div>

        <footer class="l-footer">
          <div class="l-wrap l-footer-inner">
            <span>Reviews · Open source · MIT</span>
            <a href={@repo_url}>GitHub</a>
          </div>
        </footer>
      </main>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".InstallCopy">
        export default {
          mounted() {
            this.button = this.el.querySelector("[data-install-copy]")
            this.status = this.el.querySelector("[data-copy-status]")
            this.onCopy = async () => {
              try {
                await navigator.clipboard.writeText(this.el.querySelector("[data-install-cmd]").textContent)
                this.status.textContent = "Copied"
              } catch (_) {
                this.status.textContent = "Select the command to copy it."
              }
              clearTimeout(this.timer)
              this.timer = setTimeout(() => { this.status.textContent = "" }, 3000)
            }
            this.button.addEventListener("click", this.onCopy)
          },
          destroyed() {
            clearTimeout(this.timer)
            this.button.removeEventListener("click", this.onCopy)
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
