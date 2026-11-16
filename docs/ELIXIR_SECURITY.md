# Elixir security checks

CodeQL does not support Elixir. The `Elixir security` workflow complements
CodeQL with Sobelow for Elixir/Phoenix and `mix hex.audit` for Hex packages.
It runs on pull requests, pushes to main, weekly, and manually.

## Sobelow

Run `MIX_ENV=test mix sobelow --private --strict` locally. CI writes SARIF
using `--format sarif --out sobelow.sarif` and uploads it to GitHub's
**Security → Code scanning** with category `sobelow`.

All confidence levels are reported. Confidence is not severity: a
low-confidence finding can still identify a serious vulnerability. Findings
are initially report-only, rather than failing every PR for existing issues.
Scanner failures and parse errors fail the job (`--strict`); unreadable-file
warnings remain visible in the report. Review findings individually before adding narrowly
scoped, documented suppressions. No blanket baseline or skip list is applied.

The scanner runs in GitHub Actions, not a separate hosted scanning service.
`--private` disables its update check. The workflow uses `pull_request`, never
`pull_request_target`, does not persist checkout credentials, does not use
repository secrets, and grants only the scan job `security-events: write` for
SARIF uploads. Fork PRs retain GitHub's restricted token behavior; GitHub code
scanning supports SARIF uploads for `pull_request` runs.

## Hex dependencies

Run `mix hex.audit` locally. The audit fails for known vulnerabilities in
`mix.lock`; it does not silently upgrade dependencies or ignore advisories.
The weekly run checks for newly published advisories even without code changes.
Resolve affected dependencies in a reviewed update PR.

## Initial triage (Sobelow 0.18.1)

Keep the seeded demo backend. The two `Traversal.FileModule` findings in
`Reviews.DemoReview.seed!/0` are false positives for request-controlled path
traversal: both filenames are fixed literals, and `examples_dir/0` resolves the
application's `priv/examples` directory (or a process-working-directory
fallback). Neither read accepts a request parameter. Reassess if those paths
become configurable or user-controlled; do not remove the seed or fixtures to
silence the scanner. They remain visible rather than applying a broad skip.

The `Config.CSP` label says "Missing Content-Security-Policy", but Phoenix's
`put_secure_browser_headers` already supplies `base-uri 'self'; frame-ancestors
'self';`. A stricter script/resource policy is separate hardening, not evidence
of an exploitable XSS. It needs compatibility testing and a hash/nonce or
external replacement for the inline theme script.

The `/live` socket inherits the explicit production origin allowlist from
`config/runtime.exs`. The live-reload socket is inside the `code_reloading?`
branch. These warnings do not establish production cross-site WebSocket
hijacking. Development disables origin checks and binds loopback; browser-origin
attacks can still reach loopback, so tightening development origins is useful
separate hardening. Verify deployed configuration and handshake rejection before
closing origin-related findings as false positives.
