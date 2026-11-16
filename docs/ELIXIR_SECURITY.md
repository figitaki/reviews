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
Scanner failures and unreadable/unparseable source are not ignored; `--strict`
fails on parse errors. Review findings individually before adding narrowly
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
