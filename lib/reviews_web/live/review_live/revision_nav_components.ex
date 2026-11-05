defmodule ReviewsWeb.ReviewLive.RevisionNavComponents do
  @moduledoc false
  use ReviewsWeb, :html

  attr :nav, :map, required: true
  attr :review, :any, required: true
  attr :live_action, :atom, required: true
  attr :selected_patchset, :any, required: true
  attr :diff_style, :string, required: true
  attr :has_packet, :boolean, default: false
  attr :outline_available, :boolean, default: false
  attr :show_packet_outline, :boolean, default: true
  slot :inner_block, required: true

  def revision_nav(assigns) do
    assigns =
      assign(
        assigns,
        :revision_form,
        to_form(%{"number" => assigns.selected_patchset && assigns.selected_patchset.number})
      )

    ~H"""
    <section
      id="review-toolbar"
      class="review-toolbar"
      phx-hook=".ReviewToolbar"
      aria-label="Review controls"
    >
      <div class="review-toolbar-context">
        {render_slot(@inner_block)}
        <button
          :if={@outline_available && !@show_packet_outline}
          id="review-outline-toggle"
          type="button"
          class="review-nav-button review-outline-toggle"
          phx-click="toggle_packet_outline"
          aria-label="Show section navigation"
        >
          <span class="review-outline-toggle-full">Show navigation</span>
          <span class="review-outline-toggle-short" aria-hidden="true">Sections</span>
        </button>
        <.form
          :if={@nav.revision_count > 1}
          for={@revision_form}
          id="revision-mobile-nav"
          class="review-mobile-revision-nav"
          phx-change="select_patchset"
        >
          <.input
            field={@revision_form[:number]}
            id="mobile-revision"
            type="select"
            class="review-revision-select"
            aria-label="Revision"
            options={Enum.map(@nav.revisions, &{"v#{&1.number}", &1.number})}
          />
        </.form>
        <nav
          :if={@nav.revision_count > 1}
          id="revision-nav"
          class="review-revision-nav"
          aria-label="Review revisions"
        >
          <span class="sr-only">Revision {@nav.selected_index} of {@nav.revision_count}</span>
          <button
            id="previous-revision"
            type="button"
            class="review-nav-button"
            phx-click="select_patchset"
            phx-value-number={@nav.previous_revision && @nav.previous_revision.number}
            disabled={!@nav.previous_revision}
            aria-label="Previous revision"
            title="Previous revision"
          >
            <.icon name="hero-chevron-left" class="size-4" />
          </button>
          <div class="review-revision-chip-list" aria-label="Revisions">
            <button
              :for={revision <- @nav.revisions}
              :key={revision.number}
              id={"patchset-#{revision.number}"}
              type="button"
              class={[
                "review-revision-chip",
                revision.number == @selected_patchset.number && "is-active",
                revision.packet_present && "has-packet"
              ]}
              phx-click="select_patchset"
              phx-value-number={revision.number}
              aria-pressed={
                if(revision.number == @selected_patchset.number, do: "true", else: "false")
              }
              title={
                if(revision.packet_present,
                  do: "v#{revision.number} has a review packet",
                  else: "v#{revision.number}"
                )
              }
            >
              v{revision.number}
            </button>
          </div>
          <button
            id="next-revision"
            type="button"
            class="review-nav-button"
            phx-click="select_patchset"
            phx-value-number={@nav.next_revision && @nav.next_revision.number}
            disabled={!@nav.next_revision}
            aria-label="Next revision"
            title="Next revision"
          >
            <.icon name="hero-chevron-right" class="size-4" />
          </button>
        </nav>
      </div>
      <div class="review-toolbar-views" aria-label="View options">
        <div
          :if={@has_packet}
          id="code-view-switcher"
          class="review-code-view-switcher"
          role="tablist"
          aria-label="Code view"
        >
          <.link
            navigate={guide_path(@review, @selected_patchset)}
            class={["review-code-view-tab", @live_action != :changes && "is-active"]}
            role="tab"
            aria-selected={if(@live_action != :changes, do: "true", else: "false")}
          >Guide</.link>
          <.link
            navigate={diff_path(@review, @selected_patchset)}
            class={["review-code-view-tab", @live_action == :changes && "is-active"]}
            role="tab"
            aria-selected={if(@live_action == :changes, do: "true", else: "false")}
          >Diff</.link>
        </div>
        <.diff_style_switcher diff_style={@diff_style} />
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ReviewToolbar">
        export default {
          mounted() {
            this.appbar = this.el.closest(".review-page").querySelector(".ds-shell-topbar")
            // Keep measurements outside LiveView's patched attributes.
            this.layoutStyle = document.createElement("style")
            document.head.append(this.layoutStyle)
            this.measure = () => {
              const appbarPosition = getComputedStyle(this.appbar).position
              const appbarHeight = ["sticky", "fixed"].includes(appbarPosition)
                ? this.appbar.getBoundingClientRect().height
                : 0
              const toolbarHeight = this.el.getBoundingClientRect().height
              this.layoutStyle.textContent = `.review-page {
                --review-app-nav-h: ${appbarHeight}px;
                --review-toolbar-h: ${toolbarHeight}px;
                --review-main-nav-h: ${appbarHeight + toolbarHeight}px;
              }`
            }
            this.observer = new ResizeObserver(this.measure)
            this.observer.observe(this.appbar)
            this.observer.observe(this.el)
            this.measure()
          },
          destroyed() {
            this.observer.disconnect()
            this.layoutStyle.remove()
          }
        }
      </script>
    </section>
    """
  end

  attr :diff_style, :string, required: true

  def diff_style_switcher(assigns) do
    ~H"""
    <div
      class="review-diff-style"
      id="diff-style-toggle"
      role="group"
      aria-label="Diff layout"
      phx-hook=".DiffStylePref"
      data-tablet-query="(max-width: 1024px)"
    >
      <button
        id="diff-style-split"
        type="button"
        phx-click="select_diff_style"
        phx-value-style="split"
        aria-pressed={if @diff_style == "split", do: "true", else: "false"}
        aria-label="Split diff"
        title="Split diff"
        data-requires-wide="true"
        class={["review-layout-button", @diff_style == "split" && "is-active"]}
      >
        <.icon name="hero-table-cells" class="w-4 h-4" />
      </button>
      <button
        id="diff-style-unified"
        type="button"
        phx-click="select_diff_style"
        phx-value-style="unified"
        aria-pressed={if @diff_style == "unified", do: "true", else: "false"}
        aria-label="Stacked diff"
        title="Stacked diff"
        class={["review-layout-button", @diff_style == "unified" && "is-active"]}
      >
        <.icon name="hero-queue-list" class="w-4 h-4" />
      </button>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DiffStylePref">
        export default {
          mounted() {
            const KEY = "reviews:diffStyle"
            const tabletQuery = this.el.dataset.tabletQuery || "(max-width: 1024px)"
            const media = window.matchMedia(tabletQuery)
            const splitButton = this.el.querySelector("#diff-style-split")
            const saved = () => localStorage.getItem(KEY)
            const currentStyle = () => {
              const currentBtn = this.el.querySelector('[aria-pressed="true"]')
              return currentBtn?.id === "diff-style-unified" ? "unified" : "split"
            }
            const pushStyle = (style, viewport = media.matches ? "tablet" : "wide") => {
              this.pushEvent("select_diff_style", { style, viewport })
            }
            this.syncViewport = () => {
              const tablet = media.matches
              this.el.classList.toggle("is-tablet-locked", tablet)
              splitButton?.toggleAttribute("disabled", tablet)
              splitButton?.setAttribute("aria-disabled", tablet ? "true" : "false")

              if (tablet && currentStyle() !== "unified") {
                pushStyle("unified", "tablet")
              } else if (!tablet) {
                const preferred = saved()
                if (preferred === "split" || preferred === "unified") {
                  if (preferred !== currentStyle()) pushStyle(preferred, "wide")
                } else if (this.wasTablet && currentStyle() !== "split") {
                  // Tablet forced unified; with no saved preference, go
                  // back to the default once the viewport is wide again.
                  pushStyle("split", "wide")
                }
              }

              this.wasTablet = tablet
            }

            this.syncViewport()

            const onMediaChange = () => this.syncViewport()
            if (media.addEventListener) media.addEventListener("change", onMediaChange)
            else media.addListener(onMediaChange)
            this.cleanupMedia = () => {
              if (media.removeEventListener) media.removeEventListener("change", onMediaChange)
              else media.removeListener(onMediaChange)
            }

            this.el.addEventListener("click", (e) => {
              const btn = e.target.closest("[phx-value-style]")
              if (!btn) return
              const style = btn.getAttribute("phx-value-style")
              if (media.matches && style === "split") {
                e.preventDefault()
                e.stopPropagation()
                pushStyle("unified", "tablet")
                return
              }
              if (style === "split" || style === "unified") {
                localStorage.setItem(KEY, style)
              }
            })
          },
          updated() {
            this.syncViewport?.()
          },
          destroyed() {
            this.cleanupMedia?.()
          }
        }
      </script>
    </div>
    """
  end

  defp guide_path(review, selected_patchset) do
    suffix = patchset_query(selected_patchset)
    "/r/#{review.slug}#{suffix}"
  end

  defp diff_path(review, selected_patchset) do
    suffix = patchset_query(selected_patchset)
    "/r/#{review.slug}/changes#{suffix}"
  end

  defp patchset_query(nil), do: ""
  defp patchset_query(%{number: number}), do: "?patchset=#{number}"
end
