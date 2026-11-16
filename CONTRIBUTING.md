# Contributing

Reviews is a Phoenix 1.8 and LiveView app with diffs rendered by
[`@pierre/diffs`](https://www.npmjs.com/package/@pierre/diffs), plus a Rust CLI
in `cli/`. [`AGENTS.md`](AGENTS.md) has the commands, where code lives, the
decisions already made, and the conventions for people and agents.

## Run it locally

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

To point the CLI at your server, enter `http://localhost:4000` at the
`reviews login` prompt. To build the CLI from source, run
`cargo build --manifest-path cli/Cargo.toml --release` and use
`cli/target/release/reviews`.

## Tests

```sh
mix precommit                 # warnings as errors, unused deps, format, tests
cd assets && bun run test     # JS unit tests
cd cli && cargo test          # CLI tests
```

## Browser security

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

## More docs

- [`docs/CONTRACTS.md`](docs/CONTRACTS.md): the REST API and LiveView hook
  contracts.
- [`docs/RELEASE.md`](docs/RELEASE.md): how to cut a release.
- [`docs/PREVIEW_ENVS.md`](docs/PREVIEW_ENVS.md): per-PR preview apps.
- [`docs/POPPY.md`](docs/POPPY.md): the Poppy integration in detail.
- [`docs/MCP.md`](docs/MCP.md): the prototype MCP server, which is off on the
  hosted service.
