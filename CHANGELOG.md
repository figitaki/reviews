# Changelog

All notable changes to Reviews will be tracked here.

Reviews uses semantic versioning. The first non-alpha release is 0.0.1;
later fixes continue toward 0.0.2.

## [Unreleased]

- The review page is full width at every screen width. On wide screens the
  Comments button no longer reserves a column beside the content: it floats
  in the bottom-right corner with its log above it, as on tablets. The log
  starts closed (an open choice is still remembered in this browser) and
  closes on a tap outside it, and the section decision bar stops short of the
  button above 640px. Guide diffs span the content width; the Guide no longer
  pads its right side to balance the section rail. Prose keeps its reading
  width.

- The section decision collapses on every screen width, as on phones: one
  button shows the current decision (or "Decide") and expands the full bar;
  Escape or the close button collapses it. Signed-out readers get the same
  control, and expanding it offers "Sign in to decide", which returns to the
  review with that section and its decision open.

- Add stable API and MCP error codes while retaining legacy fields and Poppy authentication responses; teach the CLI to read them.

- Pin REST, Poppy and CLI comments to exact revisions, validate anchors in the domain layer, and accept replies without placeholder locations.

- Validate packet shape, hunk references, slices and changed-line coverage in the domain layer for all revision uploads.

- Keep empty hunk rows when validating and rendering packet slices, matching the CLI; no-newline markers stay attached to their preceding row.

- Add bounded REST and Poppy file, thread and comment pages with pinned revisions, query-bound cursors and UTF-8-safe comment continuation. REST/Poppy use the shared `Reviews.Paging` limits and codec with scopes distinct from MCP.

- Expose comment IDs, safe verification attribution and projected anchor state consistently across API readers.

### Security

- Plug 1.20.4 fixes EEF-CVE-2026-120287: the multipart `:length` limit did not
  count part and header framing. It was taken one day after release, as an
  approved exception to the seven-day dependency rule.
- Only the review owner or a thread's author can resolve or reopen a thread,
  and only the review owner can decide packet sections. Before, any signed-in
  identity could do both on any review through the API (#176). Anyone else now
  gets a 403, the review page hides those controls from them, and the CLI
  explains the refusal. Commenting is unchanged: anyone signed in with the
  link can comment. The rules live in `Reviews.Policy` and apply to every
  surface.

### Changed

- Toolchain moved to Elixir 1.20.4 / Erlang 28.5.0.7 (Dockerfile, CI).
  Elixir 1.20.4 includes the fix for CVE-2026-75758.
- Phoenix 1.8.15, LiveView 1.2.12, Tailwind CLI 4.3.3, esbuild 0.28.2 and
  other dependency updates. Diff rendering moves to @pierre/diffs 1.6.4 and
  packet navigation to @pierre/trees 1.0.0.
- Comments start from Pierre Diffs' gutter button beside the line number,
  replacing the row-end comment button. Selected text within the line still
  becomes the comment's anchor. Threads are more compact, with Resolve at the
  right of the header. The collapsed comments rail is an icon with the comment
  count, left out when there are none, and a blue outline while comments are
  unread; the open rail shows a close mark. On phones, threads no
  longer break up the diff: a line with threads shows a comment button beside
  its line number, with a badge counting its comments and a keyboard focus
  ring, and tapping it shows them under the highlighted line. Phones hide line
  numbers, so the gutter only holds the change bar and the comment buttons. The
  composer stays inline under its line instead of a floating panel, inputs use
  16px text so focusing them does not zoom the page, and keyboard hints are
  hidden. Opening a composer in a large virtualized file keeps your place.
- On phones, Guide prose keeps a 16px inset from the screen edge while diffs
  stay full width.
- On wide screens, comments are a chat-style activity log pinned to the lower
  right, beside the code: recent comments oldest first and newest at the
  bottom, each with its author, time, file:line, the first two lines of the
  comment fading out, and a one-line quote of the comment a reply answers.
  Unread comments are marked. Clicking an entry opens its thread. New comments
  append while you are on the page, and the log keeps its entries for the
  visit. It collapses to an icon, remembers that in this browser, and renders
  nothing when a review has no comments.
- The Comments button is a small button fixed in the bottom-right corner at
  every width, floating over the content. Opening it no longer grows the
  button: the log opens as a separate panel above it with a short transition.
  On phones the Comments button stays visible with no comments, and the log
  closes on a tap outside it. The section decision bar and the Comments button
  now stack above sticky diff file headers, using named z-index layers in
  `tokens.css`.
- The OAuth issuer runs on [gatekeep](https://github.com/figitaki/gatekeep)
  (`Reviews.OAuth`). Endpoints, metadata, scopes, the agents-only rule,
  refresh rotation, DPoP, and Settings → Connected agents work as before, and
  a migration copies existing grants, tokens, and registered clients into
  gatekeep's tables, so no one signs in again. New codes and tokens start with
  `gkc_code_`, `gka_`, and `gkr_` instead of `ppc_`, `ppa_`, and `ppr_`.
  Issuer metadata adds `response_modes_supported`, and resource metadata adds
  `bearer_methods_supported`.
  Revoking an access token at `/oauth/revoke` now revokes only that token, not
  its grant; revoking the refresh token still ends the grant. The old OAuth
  tables stay for one release.

- One error vocabulary, `Reviews.Errors`, gives every surface the same
  codes, statuses and safe default details. MCP error results use it as
  REST and Poppy do; unknown reasons become `write_failed`. It adds
  `invalid_pagination` and `invalid_packet`.

- Section decisions belong to the account, not one identity: a person and
  their agent identities share one decision per section, and each decision
  records which identity made it. A migration merges existing decisions,
  keeping each account's most recent one. `POST .../decision` now sets the
  status explicitly and accepts `"pending"`; posting the same status again
  no longer clears it, so retries are safe. `reviews section` accepts
  `pending`. Decision writes lock the patchset row and load their own state.

- MCP follows the same permission rules as the web page, REST and Poppy. Any
  token can now read and comment on a review it has the link to, as on the web.
  Pushing revisions and resolving threads still need the review owner (or, to
  resolve, the thread's author). Every surface now passes a `Reviews.Principal`
  to the domain, and `Reviews.Policy` checks reads, comments and OAuth scopes
  too. The unchecked `Reviews.append_patchset/2` is renamed
  `append_patchset_unchecked/2`.

### Added

- A design catalog at `/design` shows the tokens and `ds_` components in the
  dark and light themes side by side, with every pill style in use. It is on
  in dev and on preview apps, and off in production. A new `<.ds_chip>`
  component gives filters and toggles one shared pill style.

- Review list (#47). `/reviews` on the web, `GET /api/v1/reviews` in the API,
  and `reviews list` in the CLI. The list has only reviews you wrote or took
  part in, with filters for role, status, author, and title or slug. A token
  for an agent identity lists only that agent's reviews. On the web the list
  is compact: one search field, a row of filter chips (role, status, and an
  author chip set by tapping an author's name), and one row per review.
  Signed-in visitors to `/` land on the list, and signing in from the home
  page returns there; an explicit `return_to` still wins.

- `reviews login` signs in from the browser on any device with the OAuth
  device authorization grant (RFC 8628): it shows a code, you enter it at
  `/device`, and the CLI stores tokens that refresh themselves. It works over
  SSH and in containers. On `/device` you choose who the tokens act as:
  you, like API tokens, or one of your agent identities.
  Settings → CLI sign-ins signs them out. `reviews login --token` keeps the
  old way, an API token pasted from Settings, and `--server` picks the server.

- The OAuth consent page can create a new agent identity for the connecting
  app, with a name and handle suggested from the app. Owners with no agents
  can now allow without leaving the page.

- Prototype hosted MCP endpoint at `/mcp`, off by default. Agents connect with
  an existing API token and can read reviews, packet sections, diffs and
  threads, and post comments, resolve threads, and push reviews and revisions
  for reviews their account owns. See `docs/MCP.md`.

### Changed

- MCP cursors now name the call they continue. A cursor sent with another
  filter, thread, section or revision is refused as invalid instead of
  skipping or repeating items. The cursor format and page limits moved to
  `Reviews.Paging`, which the REST and Poppy page endpoints will share.

### Fixed

- Faint text, green additions and red deletions now meet WCAG AA contrast
  (4.5:1) on every surface in both themes, and form-field borders meet 3:1.
  The fix is in the design tokens, so every screen picks it up.
- Home, settings, device login and the sign-in pages no longer put a
  second `<main>` landmark inside the page's own, so screen readers find
  one main region and the skip link lands on it.

- The REST and Poppy comment endpoints no longer return database error text.
  A `file_path` over 255 characters is now a `422` validation error.

- A review title, `base_sha`, `branch_name` or diff file path over 255
  characters is now a `422` validation error instead of a server error.

- `reviews whoami` works for GitHub accounts without a public email.

## [0.0.1] - 2026-11-16

The first non-alpha release promotes the existing hosted workflow: a settled
review packet contract and working comments, replies, resolution and reopening.
It does not require existing hosted users to migrate their CLI configuration.
See [docs/RELEASE_0.0.1.md](docs/RELEASE_0.0.1.md) for scope and known limits.

### Security

- Restrict browser scripts to same-origin assets, disable embedded objects, and
  restrict development WebSocket origins to the configured loopback port.

- Update Ecto to 3.14.3 to fix unbounded query cache growth from interpolated
  JSON paths and splice lists (CVE-2026-118391).

### Added

- An OAuth 2.1 issuer for APIs beyond the CLI's: authorization with PKCE and an
  owner consent page, a token endpoint with rotating refresh tokens, revocation,
  client ID metadata documents, `private_key_jwt`, dynamic client registration,
  and RFC 8414 and RFC 9728 metadata. An app only ever acts as one of the owner's
  agent identities, never as the owner, and owners can disconnect it in
  Settings. No API uses it yet.

- GitHub sign-in works on per-PR preview apps through a sign-in relay on
  production. The relay only sends users back to `reviews-pr-<N>.fly.dev`
  over HTTPS, with a code that works once, on that host, within 60 seconds.
  Production sign-in is unchanged. Setup is in `docs/PREVIEW_ENVS.md`.

- `reviews push --dry-run` (alias `--validate`) checks the diff and packet
  and prints what would be sent, without contacting the server. It lists
  every packet problem with `file:line`, flags an empty review title or
  `--update` slug, and exits 1 if there are any problems. A real push now
  also lists every packet problem at once.

- Personal Agents that support Poppy 1.0 can connect to Reviews. An owner approves one on a Reviews
  page and chooses which agent identity it acts as. Its comments show a "Verified agent" label with
  details that separate what was verified from what the agent says about itself. Owners can
  disconnect an agent in Settings. The CLI and its API tokens are unchanged. See `docs/POPPY.md`.
- Poppy Personal Agents that send DPoP proofs get tokens bound to their key, so a copied access or
  refresh token is useless without it. Agents without DPoP keep getting Bearer tokens.
- Agents whose metadata declares `dpop_bound_access_tokens: true` get no Bearer tokens: a token
  request without a DPoP proof gets `invalid_dpop_proof`. The "Verified agent" details on a comment
  say whether its token was bound to the agent's key.
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

- Markdown excerpts with missing fence, table or indentation context use Source
  with an explanation. New/deleted documents render in one complete panel.
  Large documents use virtualized Source; smaller previews reuse cached content.
  Preview changes include text labels as well as color, and document headings
  stay below review headings. Repository-relative links no longer navigate to
  unrelated review routes.
- All reviews use edge-to-edge diff cards and smaller packet gutters on mobile,
  not only reviews containing Markdown files.
- On phones, diffs, their file headers and their unmodified-lines separators
  use the full screen width, without a side gutter or rounded corners. Desktop
  is unchanged.
- Comments render safe Markdown. The collapsible comment sidebar lists only
  unread thread locations, without message previews; links prefer the first
  covering hunk in the Guide and fall back to Diff when needed.
- Preview deployments can provision and delete per-PR databases through
  Fly Managed Postgres v2, without granting SQL database-owner privileges.
- Selecting diff text offers a row-end comment button instead of opening a
  composer. File controls stay visible while scrolling on desktop and mobile;
  marking viewed collapses the diff and leaves a compact green check.
- Unified diffs wrap long lines; split diffs retain horizontal scrolling.
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
- Toolchain moved to Elixir 1.20.2 / Erlang 28.5 (Dockerfile, CI). `mix.exs`
  now requires Elixir `~> 1.20`.
- Phoenix 1.8.13, LiveView 1.2.11, Phoenix LiveDashboard 0.9.1, Bandit 1.14.1,
  Ecto SQL 3.14, Tailwind CLI 4.3.0 and other dependency updates.
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
- On phones, the open comments list keeps its height while the browser's
  toolbars collapse and expand.
- On phones, lockfiles such as `mix.lock` and `package-lock.json` scroll
  sideways instead of wrapping, so each entry stays one row. Opening a thread
  in one keeps the start of each line in view.
- Brave on iPhone no longer brings its toolbars back each time a scroll
  stops. The page now saves its scroll position for back and forward
  only when it leaves the page, not after every scroll.

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
