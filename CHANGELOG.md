# Changelog

All notable changes to Reviews will be tracked here.

Reviews uses semver with prerelease tags while the CLI and hosted service are
still stabilizing.

## [Unreleased]

### Added

- Code storage (Phase 0 + 1 of `.plans/lsp-code-storage-integration.md`):
  every code-enabled patchset gets immutable base/head Git refs stored in a
  provider-neutral backend. code.storage (Pierre) is the production adapter;
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

- Toolchain moved to Elixir 1.20.2 / Erlang 28.5 (Dockerfile, CI). `mix.exs`
  now requires Elixir `~> 1.20`.
- Phoenix 1.8.13, LiveView 1.2.11, Phoenix LiveDashboard 0.9.1, Bandit 1.12.5,
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

### Fixed

- `reviews push --range A...B` now records the merge base of A and B as the
  patchset base (matching what `git diff A...B` actually compares) instead
  of A itself.
- Diff capture is config-neutral: local `diff.algorithm`, `core.quotePath`,
  and external diff drivers no longer change the uploaded diff bytes.
- Appending a patchset no longer crashes when a non-changeset error occurs
  inside the push transaction.

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
