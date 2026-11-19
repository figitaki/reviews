# Private aggregate export

Status: part of the server, and disabled wherever the credential settings below are missing. No collector credential has been generated or installed; provisioning it requires separate authorization. Commits for this feature are signed, either with the maintainer's Turnkey GPG key or with Amp's managed SSH key, as on the rest of main. Unsigned commits are not accepted.

## Contract

`GET /api/v1/analytics/snapshot` returns exactly one fixed schema with two trailing half-open UTC windows (7 and 30 days), rounded to the source transaction's current second. There are no query parameters, body fields, custom dates, filters, groups, SQL, user IDs, or pagination. All aggregates are computed inside PostgreSQL; only aggregate JSON reaches the application process and collector.

Response keys: `version` (2), `source` (`reviews aggregate endpoint v2`), `collected_at`, `accounts`, `mcp_clients`, and `windows`. Each window has `days`, `start`, `end`, `active_accounts`, `reviews`, `revisions`, `comments`, `decisions`, `signups`, `mcp_connections`, and `mcp_active_accounts`.

Version 2 adds signups and MCP connections; version 1 had only the activity counts. A collector that checks the schema strictly must accept version 2.

- `accounts`: every account (`users` row) now. Successive snapshots give signups over time.
- `signups`: accounts created in the window.
- `mcp_clients`: one row per app, connected now: `app`, `connections` (grants at `/mcp` that are neither revoked nor expired) and `connected_accounts` (distinct accounts that approved them). Apps are the connectors in `config :reviews, Reviews.MCPAuth, connectors:` (Claude, ChatGPT), in that order, then `Unrecognized` for every other client. Only these configured names leave the database, never client IDs or client-supplied names. OAuth grants for other resources (Poppy agents, `reviews login`) are not MCP connections and are not counted.
- `mcp_connections`: `/mcp` grants approved in the window, including ones since revoked.
- `mcp_active_accounts`: distinct accounts with an `/mcp` grant used in the window, from the grant's `last_used_at`. It is separate from `active_accounts`, which counts authored activity only; an MCP comment counts in both, an MCP read only here. API tokens used at `/mcp` are not attributed to an app and are not counted.

Active accounts are distinct `identities.owner_user_id` values whose identities authored reviews, published comments, or section decisions within the window. A human identity and multiple agent identities owned by one account count once. Accounts are not people. The schema declares human/agent identity kinds; this export does not include kind subtotals, and a declared kind does not prove who operated a shared credential. Revisions count patchsets including the initial patchset, but cannot contribute attributable actors because the current schema lacks patchset actor identity. Decisions count existing rows by creation time, not subsequent changes. Deletions can change historical counts. No packet content, names, email addresses, IP addresses, actor identifiers or individual activity trails are emitted. Small operational counts remain private and are not a public anonymized dataset.

## Dedicated authentication and scope

Only a credential formatted `rva_` plus 43 URL-safe base64 characters (32 random bytes) is accepted. It is never stored in the account API-token table, and the general account authenticator explicitly rejects its namespace. An early endpoint plug also rejects this credential on every other path, including content reads and writes. A normal `rev_` account token cannot authenticate to this endpoint.

The server receives only these runtime settings through the existing secret-delivery mechanism:

- `REVIEWS_ANALYTICS_TOKEN_SHA256`: SHA-256 of the complete raw credential, hexadecimal.
- `REVIEWS_ANALYTICS_TOKEN_EXPIRES_AT`: UTC ISO-8601 expiry, positive and no more than 90 days ahead.

Missing, malformed, expired, or excessive-lifetime configuration fails closed. No startup-default credential exists. Raw credentials are compared by hashing and constant-time comparison of fixed-size digests. Authentication is checked before cache access and again before sending a response. Raw Authorization and Cookie headers are removed before downstream telemetry/loggers; requests with query strings or bodies are rejected before request logging/parsing. This route disables Phoenix router request logging and database queries use `log: false`. Responses and failures carry `Cache-Control: no-store`; there is no CORS opt-in.

The raw credential belongs only in the TinyCube collector's private token file. Do not print it, place it in a URL/command argument, reuse a user token, put it into source control, or mount it in the dashboard. Provision only after signed review and the existing deployment approvals. Generate it using a cryptographic random generator and store it directly with mode 0600 in the approved private secret destination; transmit only its hash and expiry to Reviews.

To revoke: remove the server digest/expiry from the secret configuration and complete the existing deployment's restart/rollout on **every instance**. Updating the application config on a single instance is not fleet-wide revocation. Removing/replacing the config invalidates even cached responses on that instance. Expiry is checked on every request. For rotation, install a fresh credential/hash with a fresh expiry through the approved secret workflow and update the collector; the old credential is not retained as an overlap key. No admin/write HTTP endpoint is introduced to manage credentials.

## Bounded execution

- Fixed SQL projection and fixed windows; one scalar JSON row. Each activity table is scanned once for the 30-day input, then both windows and distinct identity owners are aggregated in PostgreSQL. No timestamp index or schema migration is introduced.
- Database statement timeout 5 seconds, lock wait timeout 500ms, transaction timeout 7 seconds; no query logging. SQL performs no data modifications.
- One fixed cache entry per running application instance; 15-minute lifetime, single-flight refresh with a 10-second recovery lease, and 60-second failure cooldown. Expired values are not served by the API. The TinyCube collector retains its own last successful snapshot with visible error/stale status.
- At most 12 authenticated requests per minute **per instance**, including cache hits; 120 rejected-authentication responses per minute before returning 429. The buckets are separate and store no IPs, usernames, tokens or other identities.
- These limits are per process/instance, not a distributed DDoS protection system. Request bursts across multiple Fly Machines can multiply the limits. Instance restarts clear cache/buckets. No background timer, agent trigger, alerting, or new database role is installed.

The existing application database connection remains in Reviews. TinyCube needs only outbound HTTPS to the fixed authenticated endpoint, not a Fly-private database route or any database credential. The Fly managed-reader role could read all content and was therefore not provisioned.

## Validation and rollout

Run `mix test` with a dedicated local test database, `mix format --check-formatted`, and `mix compile --warnings-as-errors`. The privacy fixtures include sentinel packet/comment/title/user content that must never appear in exports. Tests cover exact windows, deduplication, empty datasets, credential scope/expiry/revocation, log redaction, request-shape rejection, cache single flight/expiry/failure recovery and rate limits.

For an offline query-cost check, run `elixir scripts/check_analytics_query.exs` with local `initdb`, `pg_ctl`, and `psql` on PATH. It creates and removes an isolated Unix-socket database, strips inherited PostgreSQL connection settings, and reports two JSON EXPLAIN summaries. The 700,000 synthetic activity rows, 60,000 identities, 20,000 accounts and 40,000 OAuth grants model scan width, not production data distribution or load. This is not a production latency guarantee.

Review the endpoint and TinyCube collector together. Before enabling, confirm production schema compatibility and query cost, use the existing signed release workflow, provision the separate credential through private secret channels, and test missing/wrong/expired credentials as well as a valid aggregate response. Do not activate unreviewed code or claim the endpoint is live based on local tests.

Rollback: remove the aggregate credential configuration on every instance first; revert the signed activation/release change if needed. The endpoint is disabled without valid runtime configuration. No schema migration or user-data changes need undoing.
