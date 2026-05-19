---
name: using-reviews-locally
description: Run and use the Reviews app locally, including server startup, port checks, local token setup, CLI config, pushing local reviews or new patchsets, and Codex workflow conventions. Use when the user asks to spin up Reviews, push a local review packet or revision, mint/access local API tokens, debug localhost review pushes, or install repo-local Reviews skills by symlink.
---

# Using Reviews Locally

Use this skill for local Reviews workflows from a checkout of this repo.

## Start the Server

Use the project script:

```bash
lsof -iTCP:4000 -sTCP:LISTEN
./bin/server
```

Do not run `mix phx.server` directly unless you know OAuth/env loading is unnecessary. `./bin/server` sources `.env.local` and runs Phoenix on `http://localhost:4000`.

## Local CLI Config

The CLI reads `~/.config/reviews/config.toml` and currently uses `[default]`.

Expected shape:

```toml
[default]
server_url = "http://localhost:4000"
api_token = "rev_..."
```

If the user's real default points to Fly, avoid editing it casually. For one-off local pushes, create a temporary home/config:

```bash
mkdir -p /private/tmp/reviews-local-home/.config/reviews
# write /private/tmp/reviews-local-home/.config/reviews/config.toml
HOME=/private/tmp/reviews-local-home cli/target/release/reviews push --update <slug>
```

## Mint Local Tokens

Preferred path:
1. Open `http://localhost:4000/settings`.
2. Sign in locally.
3. Generate an API token.
4. Use it in the CLI config.

Fallback for Codex when the local signed-in user exists and direct DB access is appropriate:

```bash
POSTGRES_HOST=localhost POSTGRES_PORT=<port> mix run -e 'user = Reviews.Repo.get_by!(Reviews.Accounts.User, username: "local-codex"); {:ok, _token, raw} = Reviews.Accounts.mint_token(user, %{"name" => "codex-local-push"}); IO.puts(raw)'
```

Find the DB port by inspecting the running BEAM process connections if needed:

```bash
lsof -nP -iTCP:4000 -sTCP:LISTEN
lsof -p <beam-pid> | rg "localhost:.*->localhost:"
```

Local and hosted tokens are not interchangeable.

## Push Reviews and Revisions

Create a new review:

```bash
cli/target/release/reviews push --packet /path/to/packet.md
```

Append a patchset:

```bash
cli/target/release/reviews push --update <slug> --packet /path/to/packet.md
```

Push current uncommitted work:

```bash
cli/target/release/reviews push --update <slug> --range HEAD --packet /path/to/packet.md
```

If the sandbox blocks localhost networking, rerun the CLI with escalation. If the token is rejected, mint a token in the same local database as the running server.

## Codex Workflow

- Keep local packet files in `/private/tmp` unless the user asks to commit them.
- After pushing, return the review URL and patchset number.
- Use `mix compile --warnings-as-errors`, `mix format --check-formatted`, and `mix assets.build` after relevant code/CSS/JS changes.
- If `mix test` fails before tests run because DB config points at the wrong local Postgres, report that separately from app failures.

## Install Repo-Local Skills for Testing

From this repo, symlink shared skills into Codex's skill directory:

```bash
ln -s "$PWD/skills/reviews-overview" "$HOME/.codex/skills/reviews-overview"
ln -s "$PWD/skills/writing-review-packets" "$HOME/.codex/skills/writing-review-packets"
ln -s "$PWD/skills/using-reviews-locally" "$HOME/.codex/skills/using-reviews-locally"
```

If a destination already exists, inspect it before replacing it.
