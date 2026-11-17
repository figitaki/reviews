# Changelog

All notable changes to Reviews will be tracked here.

Reviews uses semver with prerelease tags while the CLI and hosted service are
still stabilizing.

## [Unreleased]

### Security

- Restrict browser scripts to same-origin assets, disable embedded objects, and
  restrict development WebSocket origins to the configured loopback port.

- Update Ecto to 3.14.3 to fix unbounded query cache growth from interpolated
  JSON paths and splice lists (CVE-2026-118391).

### Added

- `reviews push --dry-run` (alias `--validate`) checks the diff and packet
  and prints what would be sent, without contacting the server. It lists
  every packet problem with `file:line`, flags an empty review title or
  `--update` slug, and exits 1 if there are any problems. A real push now
  also lists every packet problem at once.
- Recent comment activity with unread counts, thread links, and read state saved
  per reviewer in the current browser.
- Comments follow matching code across revisions. Discussions whose code changed
  stay available on their original revision rather than drifting onto other lines.

- Markdown diffs offer rendered Preview and exact Source views. Files open in
  Preview, including files with discussions. Explicit choices persist per review
  and file. Discussion buttons and thread links open Source for that visit,
  including from collapsed headers. Raw HTML, scripts and unsafe links stay
  escaped.

### Changed

- Migrate packet navigation to @pierre/trees 1.0.0. This release was published
  November 10, 2026 at 18:31:06.937 UTC; hold merge until November 17 at
  18:31:06.937 UTC under the seven-day dependency rule.

- Markdown excerpts with missing fence, table or indentation context use Source
  with an explanation. New/deleted documents render in one complete panel.
  Large documents use virtualized Source; smaller previews reuse cached content.
  Preview changes include text labels as well as color, and document headings
  stay below review headings. Repository-relative links no longer navigate to
  unrelated review routes.
- All reviews use edge-to-edge diff cards and smaller packet gutters on mobile,
  not only reviews containing Markdown files.
- On phones, diffs, their file headers and their unmodified-lines separators
  use the full screen width, without a side gutter or rounded corners, while
  Guide prose keeps a 16px inset from the screen edge. Desktop is unchanged.
- Comments render safe Markdown. The collapsible comment sidebar lists only
  unread thread locations, without message previews; links prefer the first
  covering hunk in the Guide and fall back to Diff when needed.
- Preview deployments can provision and delete per-PR databases through
  Fly Managed Postgres v2, without granting SQL database-owner privileges.
- Selecting diff text offers a row-end comment button instead of opening a
  composer. File controls stay visible while scrolling on desktop and mobile;
  marking viewed collapses the diff and leaves a compact green check.
- Unified diffs wrap long lines; split diffs retain horizontal scrolling.
- Comments start from Pierre Diffs' gutter button beside the line number,
  replacing the row-end comment button. Selected text within the line still
  becomes the comment's anchor. Threads are more compact, with Resolve at the
  right of the header. The collapsed comments rail is an icon with the comment
  count, left out when there are none, and a blue outline while comments are
  unread; the open rail shows a close mark. On phones, threads no
  longer break up the diff: a line with threads shows a comment button beside
  its line number, with a badge counting its comments and a keyboard focus
  ring, and tapping it shows them under the highlighted line. Phones hide line numbers, so the gutter only
  holds the change bar and the comment buttons. The composer stays inline under its line
  instead of a floating panel, inputs use 16px text so focusing them does not
  zoom the page, and keyboard hints are hidden. Opening a composer in a large virtualized file keeps your place.
- Inline conversations share one shelf with an expandable reply entry and
  compact resolved history. On mobile, conversations float above the review
  without shifting code, preserve reply text when dismissed, and follow the
  visible viewport. Empty comments cannot be submitted.
- Reseeding keeps the real demo review and its comments unless its bundled
  fixture changes.
- On phones, two icon-only floating buttons stacked above the section decision
  button replace the comments row above the section navigation: Sections, in
  the Guide only, opens the Guide map below the toolbar, and Comments, always
  shown with the comment count as a badge and a blue outline while comments are
  unread, floats the unread list above the code. A tap outside or Escape closes
  the list. The decision button
  now stays fixed to the screen inside open Guide sections.
- Section decisions keep a floating island on desktop and use a compact
  floating action button on phones, including before sign-in. After voting,
  only the selected outcome stays labeled; alternatives reveal their labels
  on hover or keyboard focus.
- The Guide map separates from the reading surface without a shadow, and
  compact section numbers stay aligned regardless of their decision state.
- Section diffs and the Changes view open without line-count or file-count
  limits. Large diffs use the existing virtualized renderer; manual collapse
  controls remain available.
- Reviews open on Overview. The guide map remembers open/closed choices and
  defaults open on desktop. The expanded map replaces the compact rail rather
  than leaving an empty strip beside it.
- Packet prose supports rich Markdown without authored HTML or remote images.
  The demo includes lists, links, emphasis, code blocks and a bundled Mermaid
  diagram rendered ahead of time.
- Review packets use one centered heading and prose layout in split and stacked
  diffs. Hiding section navigation shows every section in that layout.
- With split diffs, guide prose uses a 72ch measure. Context prose sits closer
  to the hunk it introduces. On phones the section heading comes before its
  meta row.
- Guide rail ticks are named by section number and title. The decision glyph
  has its own label, which the tick references as its description.
- Typography uses shared system-sans reading and interface roles. Decision
  controls have a padded, rounded sticky surface.
- Review titles, revisions and matching view controls share a sticky toolbar.
  Single-revision reviews omit redundant revision controls.
- Mobile review navigation uses one compact sticky row; the brand/account row
  scrolls away, Guide/Diff use icons, and multiple revisions use a native
  selector. Anonymous sign-in prompts stay in the section flow on phones.
- Below 480px the topbar brand shows only its "R" mark, and the account menu
  uses the freed width before a long user name truncates. On touch screens the
  topbar controls are at least 44px tall.
- Toolchain moved to Elixir 1.20.4 / Erlang 28.5.0.7 (Dockerfile, CI). `mix.exs`
  now requires Elixir `~> 1.20`. Elixir 1.20.4 includes the fix for
  CVE-2026-75758.
- Phoenix 1.8.15, LiveView 1.2.12, Phoenix LiveDashboard 0.9.1, Ecto SQL 3.14,
  Tailwind CLI 4.3.3, esbuild 0.28.2, @pierre/diffs 1.6.4 and other dependency
  updates. Security patches already on main (Bandit 1.14.1, Plug Crypto 2.2.1,
  Thousand Island 1.6.0, Zod 4.6.7, Phoenix HTML 4.4.0) are kept.
- JSON encoding uses Elixir's built-in `JSON` module instead of Jason for
  Phoenix, Postgrex (`jsonb` columns) and Ueberauth. The `jason` package stays
  only as a transitive dependency.
- List renders in the review, changes and settings screens carry `:key`, so
  LiveView diffs reorderings item by item.
- The `InstallCopy` and `StickyProse` hooks are colocated with their templates.
  The install snippet's CSS is colocated too via the new
  `ReviewsWeb.ColocatedCSS` module.
- LiveView test warnings for duplicate DOM ids and forms without ids now raise.
- Each preview app `reviews-pr-<N>` uses its own database, `reviews_pr_<N>`,
  created on deploy and dropped when the PR closes. Previews deploy with
  `fly.preview.toml`: one machine, a pool of 2 connections, and auto-stop
  when idle. See `docs/PREVIEW_ENVS.md`.
- Preview cleanup destroys the app before dropping its database through
  a private proxy. It works without a healthy preview release and reports
  database cleanup failures as failed jobs. Preview database credentials
  must belong to a dedicated preview cluster, not production.
- `bin/migrate` stops at the first failed step, so a failed migration now
  fails the release command instead of being ignored.

### Fixed

- GitHub sign-in now returns you to the page you started from, such as a
  review, instead of the home page. Only local paths are accepted; anything
  else goes home.

- Decode Git-quoted filenames consistently in CLI validation, uploaded file
  metadata, and review hunk lookup, including non-ASCII paths.

- Changed lines whose text starts with `--` or `++`, such as a removed SQL
  `-- note` comment, now count as changes. Packet coverage checks require them,
  and file and hunk +/- counts include them.
- Rail height and section jumps account for both headers, including wrapped
  mobile controls.
- Section jumps use native scrolling instead of a frame-by-frame animation,
  and mobile page height uses the stable small viewport.
- Diff file headers toggle across the whole row with a rotating chevron.
  Viewed state uses one independent toggle.

## [0.0.1-alpha.2] - 2026-05-21

Supersedes `0.0.1-alpha.1`, whose release build never published — its CLI
release workflow stalled on a retired macOS Intel runner. This release carries
the same changes plus the CI fix.

### Added

- New homepage with a CTA-driven walkthrough that demonstrates the review
  workflow.
- Packet outline tree navigation for moving through review packet sections.

### Changed

- CLI Linux release artifacts are now statically linked against musl
  (`x86_64-unknown-linux-musl` / `aarch64-unknown-linux-musl`). This removes
  the glibc version dependency, so the binary runs on older distros such as
  Ubuntu 22.04, Debian 11, RHEL 8, and Amazon Linux 2 without the
  `GLIBC_2.xx not found` runtime error.
- Improved the changes view with better expansion behavior and file tree.
- The diff renderer was migrated from React to a vanilla implementation.
- Production now runs on the `reviews.figitaki.dev` custom domain; the legacy
  `reviews-dev.fly.dev` hostname 301-redirects to it.

### Fixed

- The CLI release workflow now cross-compiles the macOS x64 build on an Apple
  Silicon runner instead of the retired `macos-13` Intel runner, which had been
  blocking release publication.

## [0.0.1-alpha.0] - 2026-05-19

Initial alpha baseline.

### Added

- Phoenix + LiveView web app for link-based review pages.
- Rust `reviews` CLI for pushing arbitrary git diffs into Reviews.
- GitHub OAuth sign-in, API token minting, and authenticated CLI access.
- Patchset history via `reviews push --update <slug>`.
- Draft review comments that can be published as a batch.
- Content-aware thread anchoring for carrying comments across patchsets.
- Section-aware review packet support for agent-authored review context.
- Demo review seeded for hosted and local installs.

### Notes

- The intended first release tags are `cli-v0.0.1-alpha.0` and
  `server-v0.0.1-alpha.0`.
- Syntax highlighting is still plain-text in this alpha.
- Token-range comments are intentionally deferred; the schema discriminator and
  relocation stub remain in place for a later v1.5-style pass.
