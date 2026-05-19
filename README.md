# Reviews

Reviews is a code-review tool for arbitrary diffs. It gives agents and humans a
shareable review surface before, during, or outside a GitHub PR workflow.

The app is Phoenix 1.8 + LiveView, with a React diff island powered by
`@pierre/diffs`, and a Rust CLI (`reviews push`) for uploading diffs.

## What It Provides

- Link-based reviews for any uploaded diff.
- Patchsets for iterating on the same review as the work changes.
- Review packets: markdown guides that group hunks with prose for humans.
- Lazy hunk rendering so large diffs do not eagerly mount every diff island.
- Explicit hunk viewed state shared between packet and Changes views.
- Packet section decisions for approve, deny, or ignore.
- Draft comments that can be published as a batch.

For packet-writing guidance and a reusable packet template, see
[`skills/writing-review-packets/SKILL.md`](skills/writing-review-packets/SKILL.md).
The companion skills in [`skills/`](skills/) explain the Reviews platform and
local workflow for agents.

## Prereqs

- Elixir 1.18 / Erlang 27
- Node 22+ (or Bun)
- Postgres 14+ running locally. The default dev config talks to a Postgres
  on the `/tmp` unix socket as user `reviews` (no password). To avoid clashing
  with another local project on port `5432`, set `POSTGRES_HOST=localhost` and
  `POSTGRES_PORT=55432`.

## Setup

```sh
cp .env.example .env.local
set -a; source .env.local; set +a
mix setup        # fetches deps, creates DB, runs migrations, installs assets
./bin/server     # starts the app on http://localhost:4000
```

This fetches dependencies, creates the database, runs migrations, and installs
assets.

## Running The Dev Server

Prefer `./bin/server` over `mix phx.server`. It sources `.env.local`
(gitignored) before starting Phoenix on <http://localhost:4000>.

```sh
cp .env.example .env.local
./bin/server
```

Anonymous viewing works without OAuth. Signing in, commenting, and API token
management require GitHub OAuth.

## GitHub OAuth

Register an OAuth app at <https://github.com/settings/developers> with callback
URL:

```text
http://localhost:4000/auth/github/callback
```

Then set these in `.env.local`:

```sh
GITHUB_CLIENT_ID=...
GITHUB_CLIENT_SECRET=...
```

If the env vars are missing, `/auth/github` redirects home with a flash
explaining what to set.

## CLI Workflow

Mint an API token from `/settings`, then configure the CLI:

```toml
[default]
server_url = "http://localhost:4000"
api_token = "rev_..."
```

Create a review:

```sh
cli/target/release/reviews push --packet /path/to/packet.md
```

Append a new patchset:

```sh
cli/target/release/reviews push --update <slug> --packet /path/to/packet.md
```

Use `--range HEAD` when pushing current uncommitted work.

## Layout

- `lib/reviews/` — domain contexts and schemas.
- `lib/reviews_web/` — controllers, LiveViews, plugs, and components.
- `assets/js/hooks/diff_renderer.js` — React diff island LiveView hook.
- `cli/` — Rust CLI.
- `docs/CONTRACTS.md` — REST and hook contracts.
- `skills/` — repo-local Codex skills for Reviews workflows.

## Tests

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```
