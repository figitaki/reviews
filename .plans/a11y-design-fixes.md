# a11y & design fixes (from Web Interface Guidelines review)

Findings from the design review on 2026-05-11 against `assets/js/hooks/diff_renderer.js`, `lib/reviews_web/live/review_live.ex`, `lib/reviews_web/components/layouts.ex`, `lib/reviews_web/components/core_components.ex`, `lib/reviews_web/components/layouts/root.html.heex`, and `assets/css/app.css`.

Findings are grouped by **priority** (impact × cost), not by file. Land top-down; stop wherever the budget runs out.

The `<PatchDiff>`/Shiki swap is **not** in this plan — see the planning-agent output in the session transcript or the comment block in `assets/js/hooks/diff_renderer.js:8-18`. Several findings in this plan target code that may be deleted by that swap (the in-file `DiffRow`, `parseUnifiedDiff`, etc.). Items that overlap are flagged `⚠ overlap` so they can be skipped if the swap lands first.

---

## P0 — keyboard / screen-reader breaks (do these)

### 1. Theme toggle buttons missing `aria-label`
**Where:** `lib/reviews_web/components/layouts.ex:128, 136, 144` — three icon-only `<button>` elements in `theme_toggle/1`.
**Fix:** Add `aria-label="Use system theme"`, `aria-label="Use light theme"`, `aria-label="Use dark theme"`. Also add `aria-pressed={...}` reflecting selected state (read from `data-theme` on `<html>` is awkward server-side — easiest: also add `aria-pressed` client-side from the existing `setTheme` script in `root.html.heex:11-29`).
**Why:** Three buttons with no accessible name. Screen readers announce them as unlabeled.

### 2. Theme-toggle animates `left:` not `transform:`
**Where:** `layouts.ex:126` — the sliding indicator div uses `[[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]`.
**Fix:** Replace `left-*` + `transition-[left]` with `translate-x-*` utilities and `transition-transform`. Add `motion-reduce:transition-none`.
**Why:** Animating `left` triggers layout; `transform` is compositor-only. Plus no `prefers-reduced-motion` honoring.

### 3. `transition-all` anti-pattern in show/hide JS helpers
**Where:** `core_components.ex:461-465` (`show/2`) and `:471-474` (`hide/2`) — class string is `"transition-all ease-out duration-300"`.
**Fix:** Replace `transition-all` with `transition-[opacity,transform]`.
**Why:** `transition: all` is the named anti-pattern. Triggers unintended transitions on any property change.

### 4. `<td phx-click>` row-click without keyboard support
**Where:** `core_components.ex:381-388` — `<td>` cells get `phx-click={@row_click && @row_click.(row)}` and `hover:cursor-pointer`.
**Fix (two acceptable approaches):**
- **A (preferred):** Wrap cell content in a `<.link>` or `<button>` that owns the `phx-click`. Cell stays a `<td>` for table semantics.
- **B (lower-blast-radius):** Add `tabindex="0"` to the clickable cells, plus `phx-window-keydown` or `onkeydown` that dispatches the same click on Enter/Space.
Pick A unless callers break.
**Why:** Keyboard users can't activate. Anti-pattern is a `<div>`/`<td>` with click handler.

### 5. Sticky-header / sticky-sidebar collision + no `scroll-margin-top`
**Where:** `review_live.ex:327` (`sticky top-0`) + `app.css:271` (`.rev-sidebar { top: 0 }`).
**Fix:**
- Define `:root { --rev-header-h: 3rem; }` in `app.css`.
- Header: `class="sticky top-0 z-10 ... min-h-[var(--rev-header-h)]"` (or set min-height on the header inline).
- Sidebar: change `.rev-sidebar { top: 0 }` to `.rev-sidebar { top: var(--rev-header-h) }`.
- Add `[id^="file-"] { scroll-margin-top: calc(var(--rev-header-h) + 0.5rem) }` so in-page anchors land below the header.
**Why:** Today the sidebar is hidden behind the header, and clicking a file in the tree scrolls the target under the header.

### 6. Dialog backdrop has visible text "close"
**Where:** `review_live.ex:495-502` — `<button class="modal-backdrop" ...>close</button>`.
**Fix:** Either use `<form method="dialog">` pattern, OR wrap the text in `<span class="sr-only">Close</span>` and add `aria-label="Close dialog"` on the button.
**Why:** Visible "close" text inside an invisible backdrop is a UX bug — the word appears literally over the dimmed background.

### 7. Skip-to-main link missing
**Where:** `root.html.heex:31-32` — `<body>{@inner_content}</body>` has no skip link and no `<main>` landmark.
**Fix:**
- First child of `<body>`: `<a href="#main" class="sr-only focus:not-sr-only fixed top-2 left-2 z-50 bg-base-100 border px-3 py-1 rounded">Skip to main content</a>`.
- Wrap `{@inner_content}` in `<main id="main" tabindex="-1">`.
**Why:** Keyboard users have to tab through the header on every page.

---

## P1 — visual / theming correctness

### 8. `color-scheme` not set on `<html>`
**Where:** `root.html.heex:2` — `<html lang="en">` has no `color-scheme`.
**Fix:** Add `<meta name="color-scheme" content="light dark">` to `<head>` AND set `color-scheme: light dark` on `:root` in `app.css`.
**Why:** Native scrollbars/`<select>`/form controls stay light when daisyUI flips to dark.

### 9. `<meta name="theme-color">` missing
**Where:** `root.html.heex:6`.
**Fix:** Add two metas — light: `<meta name="theme-color" content="#fafafa">`, dark: `<meta name="theme-color" content="#19232f" media="(prefers-color-scheme: dark)">`. Values come from the daisyUI `--color-base-100` definitions in `app.css:64` (light) and `:29` (dark).
**Why:** iOS Safari address bar / Chrome tab strip won't match page bg.

### 10. Patchset toggle buttons missing `aria-pressed`
**Where:** `review_live.ex:337-350`.
**Fix:** Add `aria-pressed={@selected_patchset && @selected_patchset.id == ps.id}`.
**Why:** Toggle state is encoded only in class names. SR users can't tell which patchset is selected.

### 11. `prefers-reduced-motion` global override missing
**Where:** `app.css` (add to top of file after the `@plugin` blocks).
**Fix:**
```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
  }
}
```
**Why:** Single backstop for all transitions/animations. Cheap.

### 12. Patchset / line-number buttons missing `:focus-visible`
**Where:** `review_live.ex:337` patchset buttons; `app.css:147-154` `.rdr-line-number-clickable`.
**Fix:**
- Patchset buttons: add `focus-visible:ring-2 focus-visible:ring-primary focus-visible:ring-offset-1` to the class string.
- `.rdr-line-number-clickable:focus-visible { outline: 2px solid var(--color-primary); outline-offset: -2px; }`.
**Why:** Today the only focus indicator is the UA default, which various resets nuke.

### 13. Hardcoded RGB diff colors ignore theme  ⚠ overlap with PatchDiff swap
**Where:** `app.css:131-133, 183, 203` — hardcoded greens/reds/yellows for `.rdr-row-add`, `.rdr-row-del`, `.rdr-draft`, `.rdr-draft-tag`.
**Fix:** Replace `rgba(46, 160, 67, 0.12)` etc. with `oklch(from var(--color-success) l c h / 0.12)` (or fall back to `color-mix(in oklch, var(--color-success) 12%, transparent)`).
**Why:** Dark-mode contrast is poor; not honoring daisyUI theme.
**Skip if:** the PatchDiff swap lands and these CSS classes are deleted.

### 14. `font-variant-numeric: tabular-nums` missing on line-number gutter  ⚠ overlap
**Where:** `app.css:136-145` — `.rdr-line-number`.
**Fix:** Add `font-variant-numeric: tabular-nums;`.
**Why:** Numbers misalign in proportional digit fonts.
**Skip if:** PatchDiff renders its own gutter.

---

## P2 — content / copy

### 15. Title Case pass on buttons and labels
**Fixes (single grep-and-edit pass):**
- `review_live.ex:360` `"Publish review"` → `"Publish Review"`
- `review_live.ex:371` `"dismiss"` → `"Dismiss"`
- `review_live.ex:460` `"remove"` → `"Remove"`
- `review_live.ex:491` `"Publish X comments"` — already Title Case after `Publish`; verb is fine
- `core_components.ex:81` `aria-label={gettext("close")}` → `gettext("Close")`
- `diff_renderer.js:116` `"remove"` → `"Remove"`
- `diff_renderer.js:166` `"Save draft"` → `"Save Draft"`
**Why:** Chicago-style Title Case for button/action labels.

### 16. Placeholder ending
**Where:** `review_live.ex:476` — textarea placeholder ends with `.`.
**Fix:** End with `…`: `"Optional summary that ships with the published drafts…"`.

### 17. `translate="no"` on code/identifiers
**Where:** Multiple — `review_live.ex:329` (review title), `:384, :406` (file paths in tree + per-file header), `:449` (file path in publish modal), `diff_renderer.js:222` (line content `<pre>`).
**Fix:** Add `translate="no"` attribute.
**Why:** Auto-translate garbles branch names, file paths, code.

### 18. Logo `<img>` missing `height` and `alt`
**Where:** `layouts.ex:41` — `<img src={~p"/images/logo.svg"} width="36" />`.
**Fix:** Add `height="36"` and `alt=""` (decorative — text "v…" sits next to it).
**Why:** CLS rule + missing alt.

---

## Out of scope for this plan (file as separate work)

- `<.input>` macro missing `autocomplete` / `inputmode` / `spellcheck` in its `:rest` include list (`core_components.ex:188`). Needs API-level thinking about default conventions per `type`.
- Table semantics: `<th scope="col">`, `<caption>` (`core_components.ex:370-373`).
- Heroicon component default-`aria-hidden="true"` change (`core_components.ex:451`). Touching every caller might be cleaner.
- Status icon color-only differentiation (`review_live.ex:512-520`). Letter is present, but needs `aria-label` or `<title>` per status.
- i18n: `Intl.DateTimeFormat` / `Intl.NumberFormat` everywhere we format dates/counts. Out of scope until we have any.
- CSP / `nonce` plumbing in `root.html.heex`.
- Form macro autocomplete defaults (`core_components.ex` input/textarea variants).

---

## Suggested landing order

1. **One commit, P0 items 1–7.** All low-blast-radius edits to `layouts.ex`, `core_components.ex`, `review_live.ex`, `root.html.heex`, `app.css`. `mix test` + manual smoke. Push.
2. **One commit, P1 items 8–12.** Theming metas + focus-visible. `mix test` + manual smoke. Push.
3. **One commit, P2 items 15–18.** Content pass. Trivial; bundle with #2 if the diff stays small. Note that item 15 includes a test fixture update at `test/reviews_web/live/review_live_test.exs:92` (`"Publish review (1 draft"` → `"Publish Review (1 draft"`).
4. **P1 items 13–14** land only if the PatchDiff swap is deferred; otherwise skip.

Each commit independently verifiable: `mix compile --warnings-as-errors`, `mix test`, and a curl smoke against the running dev server checking the specific aria-labels / data attributes.
