# 0.0.1 release candidate

This is preparation, not a published release. Candidate base is public main
`91b13c66f29d277cc99c974f167e7f7a72d6935a` (security PRs #135–137 included).
The latest published CLI is `0.0.1-alpha.2`, tag commit
`e211789524640d6fb0fce9ea52c94adf149e4bfc`.

## Scope and compatibility

The hosted service already has production users. The alpha exit criteria are a
reasonably settled packet format and functional comments/thread resolution.
This candidate promotes that existing behavior to `0.0.1`; further fixes can
follow in `0.0.2`. Fresh self-hosting validation is not a hosted-release gate.

Only the four version locations, changelog and release documentation change.
No runtime code, dependencies, migrations, demo fixtures or security changes
are added by this preparation. PRs #78, #132, #85 and #103 are separate work;
none is silently included or made a release prerequisite. #124 history
reconciliation is housekeeping, not a functional blocker.

The CLI packet parser and config implementation are byte-for-byte unchanged
from the published alpha.2 tag. Markdown emits `format_version: 1`; JSON uses
`title`, optional `summary`, and `sections` with `markdown` / `hunk` rows.
Hunk references and optional slices must cover changed lines exactly once.
The server preserves packet JSON on initial and subsequent patchsets.
The version bump introduces no packet or API migration. Markdown multiline
block limitations documented in `skills/writing-review-packets/SKILL.md`
remain; use a JSON markdown row for those blocks.

Existing `~/.config/reviews/config.toml` credentials remain usable. The installer
replaces the binary, preserves that config, and backs up replaced skills.
Alpha.2-to-main already includes identity and thread-resolution migrations;
those are existing main changes, not introduced here. Fresh test-schema
migration is exercised; a restored historical alpha database upgrade has not
been rehearsed. No production records were accessed or modified.

## Validation on the candidate

Local host: macOS ARM64, Rust 1.94.1, Elixir 1.20.4 / OTP 29, Bun 1.4.2,
PostgreSQL 14. CI uses Elixir 1.20.2 / OTP 28.5, Bun 1.2.13 and PostgreSQL 16.

- `cargo test --manifest-path cli/Cargo.toml --locked --offline`: 53 unit and
  2 integration tests passed (packet shape/coverage, API mocks, CLI commands).
- `cargo build --manifest-path cli/Cargo.toml --release --locked --offline`:
  passed; `reviews --version` reports `0.0.1`.
- `cargo fmt --manifest-path cli/Cargo.toml -- --check`: passed.
- `cargo clippy --manifest-path cli/Cargo.toml --locked --offline --all-targets -- -D warnings`:
  passed.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix precommit`: passed; 145 server tests passed against a dedicated local
  cluster and `reviews_test_rc001`, including API comment/reply/resolve/reopen,
  LiveView commenting/resolution, packet persistence and concurrent status updates.
- `bun install --frozen-lockfile`, `bun test`: passed, 32 JS tests.
- `mix assets.build`: passed.
- Preview cleanup integration suite: 6 tests passed against the disposable
  database cluster and a local Fly stub; no real Fly operations.
- Installer shell syntax and native archive checks: passed. Packaged root binary,
  LICENSE, README, installer and all three skills; SHA-256 verified; initial
  install and repeat upgrade worked; replaced skills backed up; config preserved;
  incorrect checksum rejected. Downloads were local fixture URLs, not a published
  candidate. This does not establish live GitHub release selection behavior.

Initial sandbox attempts could not bind mock sockets or initialize PostgreSQL;
permitted local execution passed. The machine's old Hex archive was incompatible
with OTP 29; task-local Hex 2.7.0 resolved that without global changes. Copied
old frontend dependencies initially failed; installing the existing frozen lock
resolved the failure. No product test failure remains from these attempts.

## Release tooling and limits

Main CI has no Rust test/build job. CLI tag workflow builds four targets but
runs no tests: Linux x64/ARM64 musl and macOS x64/ARM64. Local execution validates
only macOS ARM64. Other target builds/runtime checks, tagged Actions runs,
container publication and fresh self-hosting were not performed.

The CLI workflow validates its tag against Cargo.toml, packages root-level
assets and skills, generates `checksums.txt`, and sets prerelease based on `-`
in the version. Thus `0.0.1` is a non-prerelease. The server workflow validates
against mix.exs and publishes Linux amd64/arm64 images. Neither tag workflow
waits for the main test workflow: verify the selected release SHA's checks
before separately authorizing tags. Do not push all local tags: historical
alpha.1 tags differ between the local source repository and GitHub.

No browser/OAuth smoke session, published alpha binary-to-candidate server
end-to-end session, or restored alpha database migration rehearsal was run.
Compatibility evidence is unchanged packet/config code plus current CLI and
server regression suites; it is not a claim that every historical deployment
has been exercised.

## Handoff

The preparation branch is `release/0.0.1-preparation`. Turnkey signing has
resumed; preparation is authorized to proceed as a signed draft PR with a
full-diff review packet. This does not authorize tags, a published release,
merge or deployment. No unmerged feature PR is included.

Use Carey Janecka's approved Turnkey identity, include
`Co-authored-by: Turnkey <noreply@turnkey.com>`, sign the preparation commit,
and verify it locally and on GitHub. The PR and review packet record the exact
head SHA and current check results. Recheck main and the diff before releasing,
especially if other work has merged. Keep the validation gaps above visible.

After separate release authorization: settle the changelog date, review the
selected SHA's CI and local Rust results, merge through the normal process,
then create/push only the intended signed `cli-v0.0.1` and `server-v0.0.1` tags
using the agreed canonical/mirror process. Inspect all four CLI archives,
checksums, bundled skills and server images from the workflows before announcing.
A merge to main itself triggers deployment; it needs that separate authorization.
