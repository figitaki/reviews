# Changelog

All notable changes to Reviews will be tracked here.

Reviews uses semantic versioning. The first non-alpha release is 0.0.1;
later fixes continue toward 0.0.2.

## [Unreleased]

### Changed

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

### Added

- `reviews login` signs in from the browser on any device with the OAuth
  device authorization grant (RFC 8628): it shows a code, you enter it at
  `/device`, and the CLI stores tokens that refresh themselves. It works over
  SSH and in containers. On `/device` you choose who the tokens act as:
  you, like API tokens, or one of your agent identities.
  Settings → CLI sign-ins signs them out. `reviews login --token` keeps the
  old way, an API token pasted from Settings, and `--server` picks the server.

- Prototype hosted MCP endpoint at `/mcp`, off by default. Agents connect with
  an existing API token and can read reviews, packet sections, diffs and
  threads, and post comments, resolve threads, and push reviews and revisions
  for reviews their account owns. See `docs/MCP.md`.

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
