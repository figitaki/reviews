# Reviews

Reviews is a code-review tool for arbitrary diffs. It gives agents and humans a
shareable review surface before, during, or outside a GitHub PR workflow.

The app is Phoenix 1.8 + LiveView, with diffs rendered by vanilla
`@pierre/diffs` from a LiveView hook, and a Rust CLI (`reviews push`) for
uploading diffs.

Current version: `0.0.4`.

To run it on Kubernetes, see the Helm chart in
[`charts/reviews`](charts/reviews/README.md).

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

It prints a code and a link. Open the link on any device, sign in with GitHub,
enter the code, and choose who the CLI acts as: you, or one of your agent
identities. The CLI then keeps itself signed in.
This works over SSH too. Use `--server <url>` for another server (the default
is `https://reviews.figitaki.dev`), or `reviews login --token` to paste an API
token from `/settings` instead.

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

Then set `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` in `.env.local`.
Every setting the server reads, with its default and Helm value, is in
[docs/CONFIGURATION.md](docs/CONFIGURATION.md).

If the env vars are missing, `/auth/github` redirects home with a flash
explaining what to set.

## Code Storage (optional)

Reviews can store each patchset's base and head commits as Git refs, so later
features can read the source around a hunk. The backend is
[code.storage](https://code.storage). Storage is off by default, and pushes
work diff-only when it is off.

To turn it on, set `CODE_STORAGE_ADAPTER=code_storage`, `CODE_STORAGE_ORG`
and `CODE_STORAGE_JWT_PRIVATE_KEY`, and optionally `CODE_STORAGE_POLICY`, in
`.env.local` or the deploy environment. See
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#optional-features).

The server signs short-lived ES256 tokens with the private key. The CLI gets a
token that can write only the two refs of one snapshot. Signing goes through
`Reviews.CodeStorage.CodeDotStorage.Signer`; the only signer today reads the
PEM key above.

Use named-curve parameters (`prime256v1` / `secp256r1`), not explicit EC
parameters. OTP 29's PEM decoder rejects explicit parameters even for P-256.
Both actual newlines and literal `\n` separators in environment values work.
Encrypted keys, public-only keys, other curves, and bundles of keys are rejected
with `invalid_named_curve_p256_pem`; error details never include the key.

Snapshot refs remain mutable while an upload token is valid: `no-force-push`
allows fast-forwards and deletion. Future source readers must use the verified
commit IDs stored on the snapshot, rather than assume its branch refs are immutable.

With the `optional` policy, a failed upload prints a warning and the push
continues without code. With `required`, the CLI stops before it creates the
review or patchset. Use `reviews push --no-code-storage` to skip the upload
when the policy is `optional`.

The advertised `max_upload_bytes` budget is not enforced; capabilities explicitly
report `max_upload_bytes_enforced: false`. Initial uploads may include all history
reachable from the base commit. This setting does not cap transfer or storage costs.
Submodule snapshots store gitlink commit IDs, not nested uncommitted files.

The CLI asks `GET /api/v1/capabilities` first. Older servers return `404`, and
the CLI then pushes diff-only. The API contract is in `docs/CONTRACTS.md`.

## CLI Workflow

Run `reviews login --server http://localhost:4000` and enter the code it
shows at `/device`. For scripts, mint an API token from `/settings` and run
`reviews login --server http://localhost:4000 --token < token.txt`, or write
the config yourself:

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

Check a push before you send it:

```sh
reviews push --dry-run --packet /path/to/packet.md
reviews push --dry-run --update <slug> --packet /path/to/packet.md
```

`--dry-run` (alias `--validate`) runs the same packet checks as a real push,
but it does not contact the server and does not write files. It prints the
server, the review title or target slug, the diff files and hunks, and the
packet sections. It lists every packet problem with `file:line`, flags an
empty review title or `--update` slug, and exits with status 1 if there are
any problems. It also prints notes that do not change the exit status, such as
a section of only config, docs, lockfiles or generated files placed before a
section that changes code. It cannot check that the slug exists or that your
token works.

## MCP (prototype)

The server can also serve agents over MCP at `/mcp`, using the same API token.
It is on in dev and on preview apps, and off in production unless
`MCP_ENABLED=true`. For example, with Claude Code:

```sh
claude mcp add --transport http reviews http://localhost:4000/mcp \
  --header "Authorization: Bearer rev_..."
```

See [docs/MCP.md](docs/MCP.md) for the tools, access rules, and other clients.

List the reviews you wrote or took part in:

```sh
reviews list
reviews list --status updated      # a newer patchset since your last action
reviews list --role involved -q billing --json
```

The same list is on the web at `/reviews`.

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

### Browser security

Browser pages restrict scripts to same-origin assets and disable embedded objects.
The small `theme.js` bundle loads synchronously before content so saved themes
apply before first paint; keep it in the esbuild entrypoints and release assets.
Style, image and connection restrictions are deliberately not added yet, to avoid
breaking diff-renderer styles, avatars or LiveView.

Development sockets accept only `http://localhost:$PORT` and
`http://127.0.0.1:$PORT` (port 4000 by default). When using a local tunnel or
custom development host, deliberately configure its exact origin in
`config/dev.exs`; do not disable origin checking. Production keeps its existing
canonical and legacy Fly host allowlist.
