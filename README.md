# Reviews

**Code review for any diff, written for the person reading it.**

Push a diff from any Git checkout and get a link. Attach a review packet that
walks the reviewer through the change in the order it makes sense, with prose
between the hunks. Reviewers comment and approve section by section, and agents
take part under their own names.

- Hosted: <https://reviews.figitaki.dev>. See a [demo review](https://reviews.figitaki.dev/r/demo-review).
- Latest release: [CLI `0.0.1`](https://github.com/figitaki/reviews/releases/tag/cli-v0.0.1) for macOS and Linux.

```sh
curl -fsSL https://raw.githubusercontent.com/figitaki/reviews/main/install.sh | sh
reviews login
reviews push --title "Review this change"
```

## Why Reviews

**Any diff, not only pull requests.** A local branch, uncommitted work, or a
range of commits all become a shareable review. Use it before you open a PR,
alongside one, or with no PR at all. Each update is a new patchset on the same
link, and comments follow their code across patchsets.

**Review packets tell the story.** A packet is Markdown that groups hunks into
sections, puts reasoning next to the code it explains, and covers every changed
line exactly once. Reviewers approve, deny, or ignore each section, and those
decisions carry forward until the section changes. The raw Changes view is
always one click away.

**Agents are first-class reviewers.** An agent can push, comment, reply, and
decide under its own identity and API token, so its work is never mixed up with
yours. Personal Agents that support the
[Personal Agent Protocol](https://personalagentprotocol.org/docs/1.0/spec)
(Poppy) can connect after their owner approves them. Their comments carry a
"Verified agent" label that separates what Reviews verified, such as the
approving owner and the agent's domain, from what the agent only claims about
itself.

## Try it

### 1. Install the CLI

```sh
curl -fsSL https://raw.githubusercontent.com/figitaki/reviews/main/install.sh | sh
```

The installer downloads the release binary for your platform, checks its
checksum, and puts `reviews` in `~/.local/bin`. It asks whether to install the
Reviews agent skills too; pass `--with-skills --yes` or `--no-skills` to skip
the prompt, and `--version <version>` to pin a release. Run
`install.sh --help` for every option. Upgrading keeps your config.

To build from source instead, run
`cargo build --manifest-path cli/Cargo.toml --release` and use
`cli/target/release/reviews`.

### 2. Sign in

Sign in at <https://reviews.figitaki.dev> with GitHub, mint an API token at
[`/settings`](https://reviews.figitaki.dev/settings), then run:

```sh
reviews login
```

Press Enter to accept the hosted server URL and paste the token. The CLI saves
both in `~/.config/reviews/config.toml`.

### 3. Push a review

From any Git checkout:

```sh
reviews push --title "Review this change"    # last commit, HEAD~1..HEAD
reviews push --range main..HEAD              # a whole branch
reviews push --range HEAD                    # uncommitted work
```

The CLI prints a `/r/<slug>` URL to share. As the work changes, add a patchset
to the same review:

```sh
reviews push --update <slug>
```

### 4. Add a packet

Write a packet and check it before you send it:

```sh
reviews push --dry-run --packet packet.md
reviews push --packet packet.md
```

`--dry-run` (alias `--validate`) runs every packet check without contacting the
server, lists each problem as `file:line: message`, and exits 1 if there are
any. The format, with an example, is in
[writing-review-packets](skills/writing-review-packets/SKILL.md).

The CLI also reads reviews and works on threads: `reviews show`, `comment`,
`threads`, `reply`, `resolve`, `reopen`, and `section`. Run `reviews --help`
for details.

## Use it with an agent

The installer can add three skills that teach an agent when to use Reviews, how
to write a packet, and how to push and respond to feedback. See
[`skills/README.md`](skills/README.md) for Codex, Claude Code, and custom
harnesses. A useful handoff at the end of a session:

```text
Use the Reviews skills. Write a review packet for the current branch, check it
with reviews push --dry-run, push it, and give me the review URL.
```

Give the agent its own identity and token in Settings so its pushes, comments,
and decisions appear under its name.

## Documentation

| Topic | Where |
| --- | --- |
| Writing review packets | [`skills/writing-review-packets/SKILL.md`](skills/writing-review-packets/SKILL.md) |
| Agent skills and harness setup | [`skills/README.md`](skills/README.md) |
| Verified agents with Poppy | [`docs/POPPY.md`](docs/POPPY.md) and [`examples/poppy-agent/`](examples/poppy-agent/) |
| REST API and LiveView hook contracts | [`docs/CONTRACTS.md`](docs/CONTRACTS.md) |
| What 0.0.1 includes and its known limits | [`docs/RELEASE_0.0.1.md`](docs/RELEASE_0.0.1.md) |
| Release notes | [`CHANGELOG.md`](CHANGELOG.md) |
| Cutting a release | [`docs/RELEASE.md`](docs/RELEASE.md) |
| Per-PR preview apps | [`docs/PREVIEW_ENVS.md`](docs/PREVIEW_ENVS.md) |
| MCP server (prototype, off on the hosted service) | [`docs/MCP.md`](docs/MCP.md) |

## Run it locally

Reviews is a Phoenix 1.8 and LiveView app with diffs rendered by
[`@pierre/diffs`](https://www.npmjs.com/package/@pierre/diffs), plus a Rust CLI
in `cli/`.

You need Elixir 1.20 / Erlang 28, Bun or Node 22+, and Postgres 14 or later.
The dev config connects to Postgres on the `/tmp` Unix socket as user `reviews`
with no password. To avoid another project on port 5432, set
`POSTGRES_HOST=localhost` and `POSTGRES_PORT=55432`.

```sh
cp .env.example .env.local
mix setup        # deps, database, migrations, assets
./bin/server     # sources .env.local, then serves http://localhost:4000
```

Viewing reviews works without OAuth. Signing in, commenting, and minting API
tokens need a GitHub OAuth app with the callback URL
`http://localhost:4000/auth/github/callback`; put its `GITHUB_CLIENT_ID` and
`GITHUB_CLIENT_SECRET` in `.env.local`. Without them, `/auth/github` redirects
home and says what to set.

Point the CLI at your server by entering `http://localhost:4000` at the
`reviews login` prompt.

### Tests

```sh
mix precommit                 # warnings as errors, unused deps, format, tests
cd assets && bun run test     # JS unit tests
cd cli && cargo test          # CLI tests
```

Contributor and agent conventions, including where code lives, are in
[`AGENTS.md`](AGENTS.md).

### Browser security

Browser pages restrict scripts to same-origin assets and disable embedded
objects. The small `theme.js` bundle loads synchronously before content so saved
themes apply before first paint; keep it in the esbuild entrypoints and release
assets. Style, image and connection restrictions are deliberately not added yet,
to avoid breaking diff-renderer styles, avatars or LiveView.

Development sockets accept only `http://localhost:$PORT` and
`http://127.0.0.1:$PORT` (port 4000 by default). When using a local tunnel or
custom development host, deliberately configure its exact origin in
`config/dev.exs`; do not disable origin checking. Production keeps its existing
canonical and legacy Fly host allowlist.
