# 0.0.1 release

`0.0.1` is the first non-alpha release. It was cut from main at
`b013204a0fa44e8d99fe382a7790e188dd7ac34a` (#175), before the MCP server
(#155), which is planned for `0.0.2`. Both `cli-v0.0.1` and `server-v0.0.1`
point at that commit. The previous published CLI is `0.0.1-alpha.2`.

This note carries over the scope and limits from the release-candidate
preparation in #159, updated for what actually shipped.

## Scope and compatibility

The hosted service already has production users. The alpha exit criteria are a
reasonably settled packet format and working comments, replies, resolution and
reopening. This release promotes that existing behavior to `0.0.1`; further
fixes follow in `0.0.2`. Fresh self-hosting is not a release gate.

The release itself changes only version numbers and the changelog. Markdown
packets emit `format_version: 1`; JSON packets use `title`, optional `summary`,
and `sections` with `markdown` and `hunk` rows. Hunk references and optional
slices must cover each changed line exactly once. The Markdown multiline block
limits in `skills/writing-review-packets/SKILL.md` remain; use a JSON markdown
row for those blocks.

Existing `~/.config/reviews/config.toml` credentials keep working. The installer
replaces the binary, keeps that config, and backs up replaced skills. The
identity and thread-resolution migrations since alpha.2 were already deployed
from main; upgrading a restored alpha database has not been rehearsed.

## What was checked

On the released commit `b013204`:

- Main CI: Test, Publish server image and Deploy to Fly passed; the hosted
  service returns 200. The PR checks (Test, Preview, CodeQL, Sobelow, Hex audit)
  passed on its head `5f64219`.
- `release-server-image.yml` published `ghcr.io/figitaki/reviews-server` as
  `server-v0.0.1`, `0.0.1` and `sha-b013204a0fa4`, for linux/amd64 and
  linux/arm64.
- Locally (Linux x64): `cargo test --locked` (66 unit and 11 integration tests),
  `cargo fmt --check`, `cargo clippy --locked --all-targets -- -D warnings` and
  `cargo build --release --locked` passed; `reviews --version` prints `0.0.1`.

On the #159 candidate (base `91b13c6`, macOS ARM64), the preparation also ran
the server, JS and preview-cleanup suites, and checked a locally built archive:
checksums, installer upgrade, config preservation and skill backup. Those checks
used local fixture URLs, not a published release.

## Known limits

- The `cli-v0.0.1` tag run built the Linux x64 and ARM64 archives, but GitHub
  rejected the `macos-14` runner for both macOS builds ("The configuration
  'macos-14-arm64-us-default' is not supported"), so the workflow published no
  GitHub release. Until a release exists, `install.sh --version 0.0.1` fails
  with a 404 and the installer's default still resolves `cli-v0.0.1-alpha.2`.
- Main CI has no Rust job, and the tag workflows build without running tests.
  Check the release commit's CI and the local Rust checks before tagging.
- Neither tag workflow waits for main's CI.
- No browser or OAuth smoke session, alpha-binary-to-server session, or
  restored-database migration rehearsal was run for this release.
- Do not push all local tags: historical alpha.1 tags differ between the
  internal mirror and GitHub.
