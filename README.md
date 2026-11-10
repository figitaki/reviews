# Reviews

Reviews is a code-review tool for arbitrary diffs. It gives agents and humans a
shareable review surface before, during, or outside a GitHub PR workflow.

The app is Phoenix 1.8 + LiveView, with diffs rendered by vanilla
`@pierre/diffs` from a LiveView hook, and a Rust CLI (`reviews push`) for
uploading diffs.

Current alpha version: `0.0.1-alpha.2`.

## What It Provides

- Link-based reviews for any uploaded diff.
- Patchsets for iterating on the same review as the work changes.
- Review packets: markdown guides that group hunks with prose for humans.
- Lazy hunk rendering so large diffs do not eagerly mount every diff island.
- Explicit hunk viewed state shared between packet and Changes views.
- Packet section decisions for approve, deny, or ignore.
- Line and token comments that every viewer sees as soon as they are posted.

For packet-writing guidance and a reusable packet template, see
[`skills/writing-review-packets/SKILL.md`](skills/writing-review-packets/SKILL.md).
The companion skills in [`skills/`](skills/) explain the Reviews platform and
local workflow for agents. For Codex, Claude, and custom harness integration,
see [`skills/README.md`](skills/README.md).

## Install The CLI

Released CLI builds are published from `cli-vX.Y.Z` tags. The first alpha CLI
tag is `cli-v0.0.1-alpha.0`. The installer downloads the right binary for macOS
or Linux and can optionally install the repo's agent skills:

```sh
curl -fsSL https://raw.githubusercontent.com/figitaki/reviews/main/install.sh | sh
```

Use `--with-skills --yes` for non-interactive agent setup, or `--no-skills` for
binary-only installs.

You can also build the CLI from source in a repo checkout:

```sh
cargo build --manifest-path cli/Cargo.toml --release
```

Then either put `cli/target/release/reviews` on your `PATH` or use that path in
place of `reviews` in the examples below.

Then connect it to a Reviews server:

```sh
reviews login
```

For the hosted alpha, use `https://reviews.figitaki.dev` as the server URL and
mint an API token from `/settings`.

## Getting Started

```sh
cd path/to/any/git-checkout
reviews push --title "Review this change"
```

The CLI prints a review URL. Share that URL with a teammate or an agent. As the
branch changes, add a new patchset to the same review:

```sh
reviews push --update <slug>
```

At the end of a Codex session, a useful handoff prompt is:

```text
Use the Reviews skills already loaded in this session. Push the current branch
to Reviews, open the generated review URL, inspect the diff and review packet,
leave comments for any correctness or UX issues.
```

## Prereqs

- Elixir 1.20 / Erlang 28
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

## Code Storage (optional)

Reviews can store each patchset's base and head commits as Git refs, so later
features can read the source around a hunk. The backend is
[code.storage](https://code.storage). Storage is off by default, and pushes
work diff-only when it is off.

To turn it on, set these in `.env.local` (or the deploy environment):

```sh
CODE_STORAGE_ADAPTER=code_storage
CODE_STORAGE_ORG=<code.storage org>
CODE_STORAGE_JWT_PRIVATE_KEY="<P-256 private key, PKCS8 PEM>"
# Optional. "optional" (default) or "required".
CODE_STORAGE_POLICY=optional
```

The server signs short-lived ES256 tokens with the private key. The CLI gets a
token that can write only the two refs of one snapshot.

With the `optional` policy, a failed upload prints a warning and the push
continues without code. With `required`, the CLI stops before it creates the
review or patchset. Use `reviews push --no-code-storage` to skip the upload
when the policy is `optional`.

The CLI asks `GET /api/v1/capabilities` first. Older servers return `404`, and
the CLI then pushes diff-only. The API contract is in `docs/CONTRACTS.md`.

## CLI Workflow

Mint an API token from `/settings`, then configure the CLI:

```toml
[default]
server_url = "http://localhost:4000"
api_token = "rev_..."
```

Create a review:

```sh
reviews push --packet /path/to/packet.md
```

Append a new patchset:

```sh
reviews push --update <slug> --packet /path/to/packet.md
```

Use `--range HEAD` when pushing current uncommitted work.

## Layout

- `lib/reviews/` — domain contexts and schemas.
- `lib/reviews_web/` — controllers, LiveViews, plugs, and components.
- `assets/js/hooks/diff_renderer.js` — `DiffRenderer` LiveView hook; rendering
  code is in `assets/js/diff_renderer/`.
- `cli/` — Rust CLI.
- `docs/CONTRACTS.md` — REST and hook contracts.
- `CHANGELOG.md` — release notes, starting with `0.0.1-alpha.0`.
- `skills/` — repo-local Codex skills for Reviews workflows.
- `install.sh` — release installer for the CLI and optional agent skills.

## Tests

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```
