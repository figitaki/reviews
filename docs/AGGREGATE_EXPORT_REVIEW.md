# Aggregate export review notes

## Base and scope

This feature was staged on `reviews-private-analytics-current` at public main
`91b13c66f29d277cc99c974f167e7f7a72d6935a` from `https://github.com/figitaki/reviews.git`,
then brought up to date by merging main `0a5b51e`. After the merge the collector
authenticates as a `Reviews.Principal` (`via: :aggregate_export`, no identity or
scopes) and its errors use the shared `Reviews.Errors` codes. The SQL is unchanged:
section decisions gained `account_id`, but `author_id` still resolves to the same owner.

Adds a disabled-by-default fixed aggregate endpoint, early dedicated authentication,
expiry/revocation, bounded single-flight cache, owner-deduplicated SQL, tests and
contract/runbook documentation. No database migration, account credential, public
content permission, deployment configuration or dependency version is changed.
Human and agent identities belonging to the same owner count as one active account.
Kind subtotals are not exported; declared identity kind is not proof of a human operator.

## Validation (local, 2026-11-16, before the merge with main)

- `mix precommit`: **160 passed**, strict compilation and formatting successful,
  using a disposable local PostgreSQL cluster and separate database.
- `bun install --frozen-lockfile`; `bun run test`: **32 passed**. `mix assets.build`: passed.
- Current CI preview-cleanup Python integration tests: **6 passed**, disposable
  loopback PostgreSQL and local Fly stub only.
- `mix hex.audit`: passed, no retired or advisory packages. The advisories previously
  reported were from the stale mirror's lockfile and do not describe this base.
- `mix sobelow --private --strict --format json`: exit 0, no high/medium findings;
  four low-confidence findings in unchanged code (two fixed demo-file reads and
  two existing socket declarations). No new analytics findings. This does not
  establish that all possible security defects are absent.
- TinyCube Python tests: **18 passed**, including strict schema/privacy boundaries,
  credential transport and file permissions, denied owner-header cases, inactive
  packaging and no-Funnel Serve-plan validation. Layout checks cover 320/390/768/1440px
  and missing/fresh-large-count/error/stale states.

## Query-cost evidence and limits

`python3 scripts/check_analytics_query.py` creates a disposable Unix-socket database
with 700,000 synthetic activity rows (100k reviews, 200k revisions, 300k comments,
100k decisions), 60k identities / 20k owners, 90 days of activity and 1KiB synthetic
payload per activity row. Simplified tables have primary/author indexes and no
creation-time index. They model scan width, not the complete production schema,
cardinality, storage or load. No production data is copied or queried.

Two `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` runs took **850.564ms / 631.315ms**.
Each of the four activity tables and identities was scanned once (one loop).
Shared read blocks: 85,113 / 84,791; hit blocks: 15,228 / 15,550.
Both runs spilled 2,805 temporary read / 2,812 written blocks at 4MiB work_mem.
This confirms the revised plan avoids repeated base-table scans, but also shows
nontrivial I/O and temporary sorting. It is not a production latency guarantee.
The endpoint retains a five-second statement timeout, fifteen-minute cache and
single-flight refresh. No speculative index migration or DB tuning is included.
Production plan/cost assessment remains an activation gate; larger datasets or
concurrent load can return a generic unavailable response rather than a snapshot.

## Remaining gates

Turnkey signing has been restored. This change is prepared for signed review,
not activation. No real credential has been created or installed. No production
queries, deployment, Tailscale Serve/ACL/Funnel changes or kubeconfig access occur
as part of publication. Image builds, endpoint deployment, owner-phone and
non-owner checks, ACL verification and persistent private forwarding remain gates.
Serve activation requires action-time confirmation.

The current repository preview workflow deploys on draft PR creation when enabled.
Publication must not trigger that workflow without separate deployment authorization
or an approved mechanism that prevents preview deployment. The API remains disabled
unless its dedicated runtime credential configuration is provisioned.
