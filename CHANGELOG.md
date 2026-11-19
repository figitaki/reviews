# Changelog

All notable changes to Reviews will be tracked here.

Reviews uses semantic versioning. The first non-alpha release is 0.0.1.

## [Unreleased]

- Amp is a recognized app when it connects to `/mcp`. Its sign-in page shows
  Amp's name and logo instead of "Not verified".
- In the Guide each section has one compact bar at the bottom of the screen
  at every width: previous section on the left, the decision
  pill in the middle and next section on the right. It replaces the
  "Next:" and "Begin review" button at the end of each section and the
  old corner decision button and shelf. The pill shows your decision on the
  current version (Approved, Changes requested or Skipped), or "Decide".
  Clicking it floats Request changes, Skip and Approve in a row above it,
  with no panel around them and Skip over the pill (on phones the first
  reads "Changes"), and reads
  "Dismiss"; choosing one, clicking elsewhere, clicking it again or Escape
  closes it. Readers who are not the owner see the owner-only note there.
  Signed out, the pill reads "Sign in to decide" and goes straight to GitHub
  sign-in, which returns to that section with the decision open. The bar is fixed to the bottom of
  the screen, and Comments (and Sections on phones) stack in a column above
  the next-section button. The pill shows one outline, with or without
  keyboard focus.

- The Guide no longer adds 72px of empty space below the page on wide
  screens. That space ended the sticky Guide rail early, so it jumped up as
  you reached the bottom.

- Markdown Preview wraps at the same reading width as Guide prose and lines
  up with it, in Guide and Diff mode. The diff card, Source and code diffs
  stay full width.

- The review page's small controls share one size: the R mark, the account
  and review menu buttons, the version picker, the revision chips, the
  Guide/Diff and layout switchers and every square in the Guide map are
  `--size-control-md` (32px) tall with `--radius-sm` corners. On phones the
  version picker drops from 44px to 32px, the account button from 44px to
  32px, and the Guide map's menu, star, numbers and close are one 32px
  square each, 4px apart, with only the selected one filled. Touch screens
  keep a 44px tap target around each without the box growing. On touch
  phones the Guide map keeps the whole row on screen: the spare width is
  split into equal gaps of 4px to 12px, and each target reaches the
  midpoint of the gaps beside it, so it is 44px wide with few sections and
  narrower (42px with six sections at 390px) when the row is full. Only a
  row that does not fit even with 4px gaps, such as ten sections, scrolls
  its numbers between the menu and close. The collapsed desktop rail is held to
  the height under the headers and shares its height the same way on touch
  screens, so the close button stays on screen; with too many sections for
  4px gaps, its numbers scroll between the menu and close.

- Button labels are centred on their letters. A line box keeps the font's
  descent, so labels without descenders such as "Mark viewed" and an
  account name sat about 2px high. The new `.ds-label` class trims a label
  to cap height and baseline with `text-box`; `<.ds_button>` puts it on its
  label, and so do the account button, revision chips, Guide/Diff, Guide
  map numbers, Begin review, Mark viewed and the comment thread buttons.
  `<.ds_button>` gains `leading` and `trailing` slots for icons that are not
  a Heroicon before the label, such as the GitHub mark and the chevron on
  "Older".

- Comments read better on phones. Comments, Sections and the section
  decision sit in a bottom bar instead of floating over thread cards, and
  they step aside while you type, so they no longer cover Submit. The reply
  box stays above the on-screen keyboard. Thread cards use the full screen
  width, and an opened thread's header clears the sticky file header. Mark
  viewed is an eye button on phones.

- Comment times are short ("56min", "3h", "2d") and sit after the author's
  name, so the text uses the full width. Bodies start just past the avatar,
  with a light connector from the avatar. Resolve, Reply and Submit are the
  same buttons as the rest of the app, and the reply box has a visible
  border.

- Each thread and comment has a small link button that copies a link to
  it. Opening the link scrolls to that thread or comment below the file
  header and highlights it briefly.

- Switching split or unified view, a new or updated thread, opening the
  comment box and a theme change now update a file's diff in place, instead
  of building and highlighting it again. On a 4,562-line file, switching view
  no longer blanks the file or loses the reading position.

- Replies no longer send a file's diff again. Marking a file viewed,
  collapsing it, switching split or unified view and opening a section
  decision sent every open diff back to the browser, about 590 KB on a
  review with a 4,562-line file; they now send 1 to 3 KB.

- Syntax highlighting runs in web workers. A diff shows as plain text first
  and its colours fill in, so a large file no longer freezes the page. On a
  4,562-line file, Mark viewed, collapse, expand and opening a thread each
  blocked the page for about 2 s, and split or unified view for about 5 s;
  now no frame on those actions runs longer than about 0.26 s, and large
  files keep their colours. Switching between light and dark no longer
  highlights files again.

- Collapsing, expanding and marking a file viewed show at once, and the
  server saves the change in the background. The diff keeps its rendered,
  highlighted file while collapsed, so expanding it again does not highlight
  it again. On a 4,562-line file this took about 2 s each way and now takes
  under 160 ms.

- Opening a thread in a large file keeps the file virtualized. The diff
  scrolls to the thread's line and focuses it, instead of rendering every
  row. Before, a thread on a 4,562-line file put all 4,562 rows in the page,
  and it stayed that way for every later update to the file.

- Sizes follow the reader's browser font size. Space, radius and font-size
  tokens and every `font-size` in the stylesheets are rem, and buttons,
  fields and chips take their heights from new `--size-control-*` tokens.
  Before, someone with a larger default font got larger text crammed into
  controls that stayed the same size, while chips, small buttons and many
  labels did not grow at all. At the default size nothing moves. A test now
  fails on a px font size or a px space, radius or size token.

- A section's review state lines up on phones: when a decision was carried
  forward or made outdated, the history line sits under the label instead of
  wrapping back under the status mark, here and in the decision panel.

- Every top bar ends in one account control, `Layouts.account_menu`. Signed
  in, the avatar and name open a menu with Settings and Sign out on Home, the
  review list and Settings too, replacing their Settings link. Signed out, the
  review page's Sign in is text only like the other pages.

- The closed section decision on phones is a 48px floating button like
  Sections and Comments, and the decision panel uses the same `--radius-lg`
  and `--shadow-float` tokens instead of its own radius and two-layer shadow.
  New `--size-fab` (3rem) and `--size-fab-icon` (1.375rem) tokens size all
  three floating buttons.

- Every "Sign in with GitHub" control shows the GitHub mark, as GitHub's brand
  rules ask, through a new `<.ds_github_button>`; the comment composer's
  sign-in prompt and the section-decision sign-in button show it too. The top
  bar's primary Sign in stays text only. Buttons take an `icon` attribute, and
  confirm, deny, create, revoke, copy and paging controls now have icons.
  `/design` lists the icons in use and what each means.

- The design catalog also shows the app shell (both top bars and the account
  menu), the Pierre diff with comments, the section decision panel in each
  state, and the phone floating buttons with the decision button. A new
  `/design/layouts` frames the real list, review and Settings pages at desktop
  and phone widths. All of it stays off in production.

- Packets have a default section order: the core change first, then what
  follows from it (callers, schema, tests), then glue (config, generated
  files, lockfiles, docs). The writing-review-packets skill shows it as the
  default, not a rule. `reviews push --dry-run` prints a note when a section
  of only glue files comes before a section that changes code. Notes do not
  change the exit status or stop a push.

- Poppy Personal Agents whose identity key Turnkey holds show "Delegation:
  signed by Turnkey" on their comments when the delegation matches Turnkey's
  draft `poppy-delegation/v1` profile. They still act as the agent identity
  their owner approved. Client assertions may carry a 256-character `jti`, as
  that profile allows (gatekeep, figitaki/gatekeep#7). See "Turnkey-held
  identity keys" in `docs/POPPY.md`.

- `<.ds_button>` is the one button. It renders a link when given `navigate`,
  `patch` or `href`, comes in `sm` (28px), `md` (32px) and `lg` (40px, the
  height of a field), no longer lifts on hover, and keeps a 44px tap target on
  touch screens. The `.r-button` styles are gone.

- `<.input>` styles every field with the design system: a label above, 40px
  fields with 14px text (16px on touch screens, so iOS no longer zooms in), a
  readable placeholder, and a red border, `aria-invalid` and message on errors.
  Callers no longer pass `class="ds-input"`.

- A component playground at `/design/components` mounts the review page's
  comment thread, composer and floating buttons from their real code with
  sample data, in both themes and in phone and tablet frames. Replies and
  resolving work there but save nothing. `/design` now also shows every
  button and field state and says how each one behaves.

- The "Verified agent" Token row for a DPoP-bound comment reads "Access token
  bound to agent key", so it can't be read as the Session JWT's key. The
  Bearer row is unchanged.

- A review link that doesn't exist now shows a "Review not found" page with
  a 404 status, instead of sending you to the home page with a brief message.
  Any other unknown address shows a "Page not found" page in the app's usual
  look, with the top bar and a link home, in place of plain "Not Found" text.

- A review's owner can delete it for good (#202), from the review page's
  options menu, `DELETE /api/v1/reviews/:slug`, or `reviews delete <slug>`.
  The owner confirms by typing the slug, and the warning says when other
  people's or agents' comments will go too. Deletion removes patchsets,
  packets, threads, comments, section decisions and viewed-hunk state. The
  link then shows "This review was deleted" with status 410, and the API
  answers `410` `review_deleted`.

- Create a new agent identity while approving `reviews login` on `/device`, without leaving the sign-in page.

- Packet hunk links reveal their section and expand the target card on direct
  load, repeated clicks, and browser history navigation.

- Comments and threads keep their posting order when two share a timestamp
  second. Order used to depend on how Postgres stored the rows.

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
  Escape or the small close button in the bar's corner collapses it.
  Signed-out readers get the same control, and expanding it offers "Sign in
  to decide", which returns to the review with that section and its decision
  open.

- Guide prose uses the same 52rem column in split and stacked diffs, so
  switching diff style no longer changes its width. On phones, section
  headings are 20px, the same size as on desktop.

## [0.0.2] - 2026-11-18

Sign in to the CLI from any browser, see every review you are part of in one
list, and connect agents without leaving the consent page. Review decisions
and thread actions are now limited to the people who should make them, and
every API speaks one set of error codes. Existing CLI configs, API tokens and
connected agents keep working.

### Added

- **Sign in to the CLI from any browser.** `reviews login` shows a short
  code; enter it at `/device` on any device, including your phone, and the
  CLI stores tokens that refresh themselves. It works over SSH and in
  containers. On `/device` you choose who the CLI acts as: you, or one of
  your agent identities. The page takes the code in one box per letter,
  accepts a pasted code, and counts down to its expiry. Settings → CLI
  sign-ins lists them and signs them out. `reviews login --token` still
  takes an API token pasted from Settings.
- **Your reviews in one list** (#47). `/reviews` lists the reviews you wrote
  or took part in, with one search field for title or slug and filter chips
  for role, status and author (tap an author's name to filter by them).
  Signed in, `/` takes you to the list. The same list is
  `reviews list` in the CLI and `GET /api/v1/reviews` in the API; a token for
  an agent identity lists only that agent's reviews.
- **Create an agent identity while connecting an app.** The OAuth consent
  page can create a new agent identity for the app, with a name and handle
  suggested from it, so an owner with no agents can allow it without leaving
  the page.

### Changed

- **Comments, redone.** Start a comment from the button beside the line
  number; text you select in the line becomes its anchor. Threads are more
  compact, with Resolve in the header.
  - On wide screens, comments are a chat-style log in the lower right:
    newest at the bottom, each with its author, time, file and line, and a
    quote of the comment it answers. Unread comments are marked, clicking
    one opens its thread, and new comments appear as they are posted.
  - On phones, threads no longer break up the diff: a line with comments
    shows a button with a count beside its line number, and tapping it
    shows them under the line. The composer stays under its line and
    focusing it no longer zooms the page.
  - The Comments button floats in the bottom-right corner at every width
    and opens its log above it. On phones it sits with the Sections and
    section decision buttons.
- **Section decisions belong to your account.** You and your agent identities
  share one decision per section, and each decision records which identity
  made it; existing decisions were merged, keeping the most recent. Choosing
  the same decision again through the API or `reviews section` no longer
  clears it, so retries are safe, and `pending` resets a section.
- **One set of error codes everywhere.** The REST API, Poppy and the CLI
  return the same stable error codes, statuses and safe messages, with the
  old fields kept. The CLI explains errors using them.
- **Paged lists in the API.** File, thread and comment lists in the REST and
  Poppy APIs come in bounded pages with cursors pinned to one revision, so
  long reviews load predictably. A cursor sent with different filters is
  refused instead of skipping or repeating items.
- **Comments are pinned to the revision they were left on**, from the web,
  the API, Poppy and the CLI. Replies no longer need a placeholder location.
  API readers return comment IDs, safe verification details for agent
  comments, and whether a comment's anchor is still current.
- Every revision upload is checked on the server for packet shape, hunk
  references, slices and changed-line coverage, the same checks the CLI runs.
  Packet slices keep empty rows, matching the CLI.
- On phones, Guide prose keeps a 16px inset while diffs stay full width.
- Updated to Elixir 1.20.4, Erlang 28.5, Phoenix 1.8.15 and LiveView 1.2.12.
  Diffs render with @pierre/diffs 1.6.4 and packet navigation uses
  @pierre/trees 1.0.0.

### Fixed

- On phones, the Guide map shows each section's decision as a small badge
  after its title, so long titles cut off in the same place and rows no
  longer wrap. The Sections button opens and closes the map, and the map
  closes when you go to another page. Diffs on phones show line numbers again,
  in a compact gutter.
- Faint text, additions and deletions meet WCAG AA contrast (4.5:1) in both
  themes, and form-field borders meet 3:1.
- Screen readers find one main region on home, Settings, device login and the
  sign-in pages, and the skip link lands on it.
- On iPhone browsers, the toolbars no longer reappear each time a review stops
  scrolling, and the floating buttons stay pinned to the bottom of the screen.
  Lockfiles scroll sideways on phones instead of wrapping.
- Titles, branch names, base SHAs and file paths over 255 characters are a
  `422` validation error instead of a server error, and comment endpoints no
  longer return database error text.
- `reviews whoami` works for GitHub accounts without a public email.

### Security

- Only the review owner can decide packet sections, and only the owner or a
  thread's author can resolve or reopen it (#176). Before, any signed-in
  identity could do both on any review through the API. Others now get a 403,
  the review page hides those controls from them, and the CLI explains why.
  Anyone signed in with the link can still comment. The same rules apply on
  the web, REST, Poppy and the CLI.
- Plug 1.20.4 fixes EEF-CVE-2026-120287, where the multipart size limit did
  not count part and header framing. It was taken one day after release, as
  an approved exception to the seven-day dependency rule.
- Elixir 1.20.4 includes the fix for CVE-2026-75758.

### For integrators

- The OAuth issuer now runs on [gatekeep](https://github.com/figitaki/gatekeep).
  Endpoints, scopes, DPoP, refresh rotation and Settings → Connected agents
  work as before, and existing grants, tokens and clients were migrated, so
  no one signs in again. New codes and tokens start with `gkc_code_`, `gka_`
  and `gkr_` instead of `ppc_`, `ppa_` and `ppr_`. Revoking an access token
  at `/oauth/revoke` now revokes only that token; revoking the refresh token
  still ends the grant. Issuer metadata adds `response_modes_supported` and
  resource metadata adds `bearer_methods_supported`. The old OAuth tables
  stay for one more release.
- `POST .../decision` sets the status you send and accepts `"pending"`.
- New error codes `invalid_pagination` and `invalid_packet`.

### Not yet live

These ship in the code but are off on reviews.figitaki.dev:

- A prototype hosted MCP endpoint at `/mcp`, off unless `MCP_ENABLED` is set.
  It follows the same permission rules and error codes as the other APIs.
  See `docs/MCP.md`.
- A design catalog at `/design`, on in development and on preview apps only.

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

- Claude custom connectors, ChatGPT connectors, and other MCP clients can sign in to `/mcp` with
  OAuth. The owner approves the app on a Reviews page, picks which of their agents it acts as (an
  app never acts as the owner) and what it may do (read, push reviews, comment), and can disconnect
  it in Settings. `search` and `fetch` tools let ChatGPT find and read reviews, and `reviews_list`
  lists the account's reviews with the same filters as `reviews list`. API tokens keep working.
  `/mcp` accepts requests from the Claude and ChatGPT origins, which
  their connector check sends. The consent page shows Claude and ChatGPT as
  recognized apps with their logos (one config list holds the known
  connectors), and groups permissions into reads, always included, and writes
  the owner can untick. See `docs/MCP.md`.
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
