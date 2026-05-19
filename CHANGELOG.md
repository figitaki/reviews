# Changelog

All notable changes to Reviews will be tracked here.

Reviews uses semver with prerelease tags while the CLI and hosted service are
still stabilizing.

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
