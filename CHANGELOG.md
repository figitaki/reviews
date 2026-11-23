# Changelog

All notable changes to Reviews will be tracked here.

Reviews uses semantic versioning. The first non-alpha release is 0.0.1.

## [Unreleased]

- A Helm chart in `charts/reviews` runs the server on Kubernetes, with its
  Postgres as a CloudNativePG cluster or a database you already have.
  Migrations run in an init container before each pod starts; seeding the
  demo review is opt-in. Every pod needs a private `RELEASE_COOKIE`. The
  chart is versioned with each release and published to
  `oci://ghcr.io/figitaki/charts/reviews` from the same `server-v<version>`
  tag as the image; chart `<version>` runs `server-v<version>` by default.
  Its README covers installing, every value, and deploying with Flux.
- phoenix_live_view is now 1.2.14, which fixes EEF-CVE-2026-126334
  (GHSA-v4p7-3pm2-wq6c): a LiveView joined without `"url"` skipped its
  `live_session` `on_mount` hooks. Reviews uses no `live_session` or
  `on_mount` hooks, so it was not exposed, but the Hex audit failed on
  1.2.12. 1.2.14 was published on 2026-11-20, so this bump is an exception
  to the 7-day release-age rule, approved by Carey for this security fix
  only. No other locked dependency changed.
- The favicon and the web app manifest now load in production. The page
  linked their digested names, such as `/site-<hash>.webmanifest`, which
  the static file allowlist refused with a 404.
- Opening a thread from Comments in Diff mode now stays in Diff mode and opens the thread there, instead of switching to the Guide and loading every diff again (#245).
- Review links now unfurl in Slack, iMessage, Discord and other apps (Open
  Graph and Twitter card tags). A link to a comment shows who wrote it, the
  file and line, and the comment as plain text. Page titles no longer end in
  "· Phoenix Framework". A comment link that opens the Changes view now keeps
  `comment`, so it still lands on that comment.
- The server now reads Markdown with MDEx (comrak), set up like the
  browser's markdown-it in `Reviews.Markdown`. Link previews use it, so a
  preview shows the same text as the rendered comment. MDEx is pinned to
  0.14.6 and mdex_native to 0.3.1, the newest releases at least 7 days old.
- A person or agent looks the same everywhere: comment threads, the account
  menu, the review list, Settings and the Guide's byline all draw them with
  one `<.ds_identity>` (avatar, name, `@handle`, and an Agent marker for
  agents). Comments now show the display name beside the handle and mark
  agents. The review list's "(agent)" becomes the same Agent marker. The
  account menu and the review list show the handle's first letter when there
  is no avatar instead of nothing. Every avatar keeps a thin ring, so a
  provider logo reads as a circle on both themes, and the Agent marker's
  outline is strong enough to see on dark. The handle is left out where it
  only repeats the name. Settings keeps its square, stacked rows.
- The Guide's Overview names who published the packet: their avatar, name
  and handle. The avatar is round and sized like comment avatars, with the
  same first-letter fallback. An agent shows its provider logo, an Agent badge, and the
  person who owns it ("owned by @carey"). The owner comes in the same query
  that already loads the author, so the review page makes no extra request.
  Settings and the Overview share the new `<.ds_avatar_mark>`.
- The diff view has a file tree again. Files sit under their folder with
  their line counts and a letter for the change (M, A, D, R); a click
  scrolls to the file's diff. On phones it folds behind a Files button.
- The Guide map uses the same tree rows: sections show their decision as a
  letter (A approved, C changes requested, S skipped), and the open
  section's files show their path, counts and change letter. Rows are 44px.

### Security

- Add bounded per-instance request budgets before expensive request handling,
  authenticate API writes before body parsing, and limit small bodies to 64KB
  while keeping authenticated 50MB review/patchset uploads and 4MB MCP
  requests. A rejected request gets `429` with `error_code: rate_limited`.
  Unsupported multipart bodies now return 415. A 429 from an OAuth endpoint
  keeps its CORS headers and exposes `Retry-After`, and `reviews login` waits
  out a 429 and keeps polling. On Fly the app now listens on IPv4 only and
  budgets use a single valid `Fly-Client-IP` (else the socket peer); IPv6
  clients share a budget per /64. See `docs/ABUSE_PROTECTION.md`.

## [0.0.3] - 2026-11-19

0.0.1 brought the CLI and API tokens, and 0.0.2 brought agents signing in
with OAuth. 0.0.3 connects Claude, ChatGPT and Amp. Add
`https://reviews.figitaki.dev/mcp` as a custom connector, sign in with GitHub,
and choose which of your agents it acts as and what it may do. Large diffs no
longer freeze the page, comments work properly on phones, and a review's owner
can delete it. Existing CLI configs, API tokens and connected agents keep
working.

### Added

- **Claude and ChatGPT connectors.** Add `https://reviews.figitaki.dev/mcp`
  as a custom connector in Claude or a connector in ChatGPT and sign in with
  GitHub. On the consent page you pick which of your agent identities it
  acts as (an app never acts as you) and what it may do: reading is always
  included, and creating reviews, commenting and resolving threads can each
  be left out. Claude and ChatGPT show as recognized apps with their logos;
  any other app shows as not verified. Disconnect it any time in Settings.
  Connectors can list the account's reviews with the same filters as
  `reviews list`, search and fetch them, read packets, diffs and threads,
  and post as the agent you chose. Agents and CLIs that use a Reviews API
  token, such as Claude Code, Codex and Amp, keep working. See
  `docs/MCP.md`.
- **Links in MCP results.** Every thread an MCP tool returns has a `url`
  that opens the review on that thread, and every comment one that opens it
  on that comment. Posting a comment returns `thread_url` and `comment_url`,
  and the feedback resource and `fetch` link each thread.
- **The Reviews icon.** The Reviews mark, the R in a rounded square from the
  top bar, is now the favicon, the home-screen icon and the icon `/mcp`
  advertises in `serverInfo.icons`. Claude shows a custom connector with its
  site's favicon, so it shows this mark instead of a plain letter.
- **Recognized apps: Amp.** Amp joins Claude and ChatGPT as a recognized
  app at `/mcp`. Its sign-in page shows Amp's name and logo instead of "Not
  verified".
- **Pick an agent's provider.** Settings → New agent identity picks the
  provider from a list: Claude, Codex, ChatGPT, Amp, Cursor, Gemini, GitHub
  Copilot and Grok, or Custom to type another name. An agent made for a
  listed provider uses its logo as its avatar.
- **Delete a review.** The owner can delete a review for good from the
  review page's options menu, `reviews delete <slug>`, or the API. You
  confirm by typing the slug, and the warning says when other people's or
  agents' comments will go too. The link then shows "This review was
  deleted".
- **Link to a thread or comment.** Each thread and comment has a small
  button that copies a link to it. Opening the link scrolls to it and
  highlights it briefly.
- **Create an agent while signing in the CLI.** Approving `reviews login` on
  `/device` can create a new agent identity without leaving the page.
- **A default packet order.** Packets read best with the core change first,
  then what follows from it (callers, schema, tests), then glue (config,
  generated files, lockfiles, docs). The packet skill shows this order, and
  `reviews push --dry-run` notes a glue-only section placed before code. A
  note never fails a push.
- **Code storage (not live yet).** With code storage on, `reviews push` also
  uploads the exact base and head commits of each revision to code.storage,
  ready for code intelligence later. It is off unless the server sets
  `CODE_STORAGE_*`, and it is off on reviews.figitaki.dev, so pushes there
  stay diff-only. `--no-code-storage` skips the upload when it is optional.
- Poppy Personal Agents whose identity key Turnkey holds show "Delegation:
  signed by Turnkey" on their comments. See "Turnkey-held identity keys" in
  `docs/POPPY.md`.

### Changed

- **Large diffs stay fast.** Syntax highlighting runs in the background, so a
  diff shows as plain text first and its colours fill in. On a 4,562-line
  file, Mark viewed, collapse, expand and opening a thread used to block the
  page for about 2 s and switching split or unified view for about 5 s; now
  no step takes longer than about a quarter of a second. Collapsing,
  expanding and marking a file viewed show at once, switching view keeps
  your place, and opening a thread no longer renders the whole file. Those
  actions also send 1 to 3 KB back to the browser instead of about 590 KB.
- **Comments on phones.** Comments, Sections and the section decision sit in
  a bottom bar instead of floating over thread cards, and step aside while
  you type so they no longer cover Submit. The reply box stays above the
  keyboard, and thread cards use the full width. Comment times are short
  ("56min", "3h", "2d") and sit after the author's name.
- **A full-width review page.** On wide screens Comments floats in the
  bottom-right corner instead of taking a column, and Guide diffs span the
  page. Guide prose and Markdown Preview keep one reading width in every
  layout.
- **One section bar in the Guide.** Each section ends in a compact bar at the
  bottom of the screen: previous section, your decision (Approved, Changes
  requested, Skipped, or "Decide"), and next section. Signed out, it offers
  "Sign in to decide" and returns you to that section with the decision open.
- MCP comments read plainly. `reviews_post_comment` and the address-feedback
  prompt ask agents to write in Simplified Technical English (ASD-STE100):
  short sentences, active voice and common words.
- On wider screens each comment's time and link button sit at the right of
  its row, level with its first line. Phones keep the time after the
  author's name.
- `reviews push --range A...B` uses the merge base of A and B as the base,
  which matches `git diff A...B`. An empty side (`main..`, `main...`) means
  HEAD. Diff capture no longer depends on local git config such as
  `diff.algorithm` or external diff drivers.
- Sizes follow your browser's font size, so a larger default font gives
  larger controls as well as larger text. At the default size nothing moves.
- Every top bar ends in the same account menu, with Settings and Sign out.
- A review link that doesn't exist shows "Review not found" with a 404, and
  other unknown addresses show "Page not found" in the app's usual look.
- Every "Sign in with GitHub" button shows the GitHub mark, and confirm,
  deny, create, revoke, copy and paging buttons have icons.

### Fixed

- Commenting on a range of lines no longer gets stuck. Closing the comment
  box after dragging the "+" across several lines now clears the selection,
  so later comments no longer start from that range.
- Packet hunk links open their section and expand the target card on direct
  load, repeated clicks and back and forward.
- Comments and threads posted in the same second keep their posting order.
- The Guide rail no longer jumps at the bottom of the page on wide screens.
- Button labels without descenders, such as "Mark viewed", no longer sit
  about 2px high, and the review page's small controls share one size.
- On phones, a section's decision history sits under its label instead of
  wrapping under the status mark.
- The "Verified agent" details for a DPoP-bound comment read "Access token
  bound to agent key", so they can't be mistaken for the Session JWT's key.

### Security

- idna is 8.0.0, which fixes EEF-CVE-2026-117678: a long Punycode label in a
  hostname could keep the CPU busy (#259). jsv still asks for idna 7, so
  `mix.exs` overrides it until jsv allows 8.

### For integrators

- `/mcp` is an OAuth 2.1 protected resource. A 401 names its protected
  resource metadata (RFC 9728); the issuer publishes authorization server
  metadata (RFC 8414) and accepts client ID metadata documents and dynamic
  client registration, with PKCE. Scopes are `reviews:read`,
  `reviews:write`, `comments:write` and `threads:write`, and every tool
  declares `readOnlyHint`, `destructiveHint`, `idempotentHint` and
  `openWorldHint`. Known connectors are one config list
  (`config :reviews, Reviews.MCPAuth, connectors:`). Reviews API tokens keep
  every scope at `/mcp`.
- `GET /api/v1/capabilities` says whether code storage is on, and
  `POST /api/v1/code-snapshots` and `/complete` reserve and check snapshot
  uploads. Push endpoints accept an optional `code_snapshot_id`, and the
  review payload shows `code_snapshot_status` per revision.
- `DELETE /api/v1/reviews/:slug` deletes a review; its link and API then
  answer `410` with `review_deleted`.
- `<.ds_button>` is the one button (`sm`, `md`, `lg`; renders a link with
  `navigate`, `patch` or `href`), `<.input>` styles every field, and
  `<.ds_github_button>` is the GitHub sign-in control. The `.r-button`
  styles are gone.

### Not yet live

- Code storage is off on reviews.figitaki.dev; see Added.
- A private aggregate analytics export (accounts, signups, active accounts,
  and MCP connections by app) is off unless its own credentials are set.
- The design catalog at `/design`, `/design/components` and
  `/design/layouts` is on in development and on preview apps only.

## [0.0.2] - 2026-11-18

Sign in to the CLI from any browser, see every review you are part of in one
list, and connect agents without leaving the consent page. Review decisions
and thread actions are now limited to the people who should make them, and
every API speaks one set of error codes. Existing CLI configs, API tokens and
connected agents keep working.

### Fixed

- Keep staging code repositories while a snapshot reservation is live or
  provider creation is in flight; recover abandoned creations for cleanup.
- Accept a code storage PEM key whose line breaks were stored as spaces, as
  single-line secret inputs do. Before, signing failed and every upload fell
  back to diff-only.
- Fix the code.storage client crashing on every request (Req rejected
  `:finch` together with `:connect_options`); the 5 s connect timeout applies.
- Code storage errors use the shared `error_code` envelope, and reservation
  checks push permission through `Reviews.Policy`.

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
- Code storage (Phase 0 and 1 of the code storage plan in #74):
  every code-enabled patchset gets verified base/head commit IDs and scoped
  Git refs in a provider-neutral backend. code.storage (Pierre) is the production adapter;
  storage is off by default (`CODE_STORAGE_ADAPTER=code_storage` enables it).
- `GET /api/v1/capabilities` for CLI feature discovery, plus
  `POST /api/v1/code-snapshots` and `POST /api/v1/code-snapshots/:id/complete`
  with a reserve → upload → verify → claim flow and stable error codes.
- `reviews push` uploads a code snapshot when the server supports it:
  resolves exact base/head OIDs, builds synthetic commits for staged or
  tracked worktree state with a fixed `Reviews Snapshot` identity, verifies
  the diff matches the snapshot, and pushes exactly two refs atomically with
  a short-lived ref-scoped credential (never written to URLs, config, or
  logs). `--no-code-storage` skips the upload where the server allows it.

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

- Enforce snapshot reservation deadlines during completion and claiming, and
  prevent late provider results from overwriting newer snapshot states.
- Ignore dirty submodule contents in snapshot diffs while preserving gitlink
  changes; disclose that the advertised upload budget is not enforced.

- GitHub sign-in now returns you to the page you started from, such as a
  review, instead of the home page. Only local paths are accepted; anything
  else goes home.

- Decode Git-quoted filenames consistently in CLI validation, uploaded file
  metadata, and review hunk lookup, including non-ASCII paths.

- `reviews push --range A...B` now records the merge base of A and B as the
  patchset base (matching what `git diff A...B` actually compares) instead
  of A itself.
- Diff capture is config-neutral: local `diff.algorithm`, `core.quotePath`,
  and external diff drivers no longer change the uploaded diff bytes.
- Appending a patchset no longer crashes when a non-changeset error occurs
  inside the push transaction.
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
