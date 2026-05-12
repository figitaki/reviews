# Reviews

A code-review tool for arbitrary diffs. Phoenix 1.8 + LiveView on the server,
React island (via `@pierre/diffs`) for the diff renderer, Rust CLI (`reviews
push`) for ingestion.

## Prereqs

- Elixir 1.18 / Erlang 27
- Node 22+ (or Bun)
- Postgres 14+ running locally. The default dev config talks to a Postgres
  on the `/tmp` unix socket as user `warbler` (no password). Override in
  `config/dev.exs` if your setup differs.

## Setup

```sh
mix setup        # fetches deps, creates DB, runs migrations, installs assets
mix phx.server   # starts the app on http://localhost:4000
```

## GitHub OAuth

Set these before starting the server if you want to actually sign in:

```sh
export GITHUB_CLIENT_ID=...
export GITHUB_CLIENT_SECRET=...
```

Register an OAuth app at <https://github.com/settings/developers> with the
callback URL `http://localhost:4000/auth/github/callback`.

Anonymous viewing works without OAuth; commenting requires sign-in.

## Layout

- `lib/reviews/` — contexts (`Accounts`, `Reviews`, `Threads`, `Anchoring`).
  Only these touch `Repo`.
- `lib/reviews_web/` — controllers, LiveViews, plugs.
- `assets/js/hooks/diff_renderer.js` — the React island hook (Stream 2a fills
  this in).
- `cli/` — Rust CLI (Stream 2b; not in this directory yet).
- `docs/CONTRACTS.md` — REST + hook contracts the streams build against.

## Tests

```sh
mix test
```
