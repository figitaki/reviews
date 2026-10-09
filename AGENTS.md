# Reviews

Reviews is a code-review tool for arbitrary diffs, not only GitHub PRs. An author pushes a diff plus a **review packet** (markdown that orders and annotates hunks into sections); reviewers read the packet, comment, and decide per section; `--update` adds patchsets.

Stack: Elixir 1.20 / Phoenix 1.8 / LiveView 1.2 (web), Rust CLI in `cli/`, Postgres, vanilla `@pierre/diffs` for diff rendering (no React). Bun manages `assets/`.

This file is for every coding agent (Claude Code, Codex, Cursor, …). `CLAUDE.md` is a symlink to it. Framework-level Phoenix/Elixir rules live in `.claude/rules/phoenix-usage-rules.md`; read that file before editing Elixir, HEEx or asset files.

## Commands

| Task | Command |
|---|---|
| First setup | `mix setup` (deps, DB, assets) and `cd assets && bun install` |
| Dev server | `./bin/server` (sources `.env.local` for GitHub OAuth, then `mix phx.server` on :4000). Check `lsof -iTCP:4000 -sTCP:LISTEN` first; a second server fails on bind. |
| Before committing | `mix precommit` (compile with warnings as errors, unused deps, format, test) |
| Elixir tests | `mix test`. Parallel runs or worktrees: `MIX_TEST_PARTITION=<name> mix test` gives each its own DB. |
| JS unit tests | `cd assets && bun run test` |
| Assets | `mix assets.build` (CI runs it; tailwind needs `NODE_PATH`, already wired) |
| CLI | `cd cli && cargo build --release`, `cargo test`, `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check` |
| Preview a change as a review | `reviews push` from any checkout, then open the printed `/r/<slug>` URL; `reviews push --update <slug>` adds a patchset; `reviews push --dry-run` validates without sending |

CI (`.github/workflows/ci.yml`) runs format check, compile with warnings as errors, `bun install --frozen-lockfile`, `mix assets.build`, and `mix test`. Match it locally before pushing.

## Where things are

- `lib/reviews/` contexts: `reviews.ex` (reviews, patchsets), `threads.ex`, `packet_section_decisions.ex`, `anchoring.ex`, `accounts.ex` (users, agent identities, API tokens), `code_snapshots.ex` + `code_storage/` (optional code.storage backend).
- `lib/reviews_web/live/review_live.ex` is the review screen; its packet UI is in `review_live/packet_components.ex`, diff components in `review_live/diff_components.ex`. `settings_live.ex` holds identities and tokens.
- `lib/reviews_web/controllers/api/` is the JSON API the CLI uses. `docs/CONTRACTS.md` documents it and the LiveView hook events; update it with any API change.
- `assets/js/hooks/diff_renderer.js` mounts Pierre; rendering code is in `assets/js/diff_renderer/`; dataset parsing goes through Zod schemas in `assets/js/schemas.js`.
- `assets/css/app.css` imports `tokens.css`, `components.css`, `packet.css` (review UI, `.review-*` / `.rev-*`), `landing.css`, `product-shell.css`. Use the `--ds-*` tokens; do not add hex colours in components.
- `.plans/` holds design plans and is tracked. Read the plan for the area you touch before changing it. `.plans/market-scan-2026-10.md` lists product ideas with prior art.
- `skills/` are the agent skills shipped with the CLI installer (overview, writing packets, using Reviews locally). Keep them in sync with CLI flags.
- `docs/RELEASE.md` is the release process; `CHANGELOG.md` has an Unreleased section to add to.

## Decisions already made

Do not reopen these without the maintainer.

- Input is the CLI only; no web paste.
- Sharing is link-based: anyone with the URL can view. Commenting needs GitHub OAuth or an API token.
- Comments publish immediately. Per-viewer drafts were removed (`priv/repo/migrations/20260519120000_drop_draft_review_support.exs`).
- Decisions are per packet section, per patchset, per identity (`approved`, `denied`, `ignored`, `pending`) and carry forward to later patchsets until the section changes.
- Agent identities are first-class: an agent can push, comment and decide under its own handle and token.
- Threads carry across patchsets by content, not line numbers. `Anchoring.relocate/3` matches a line by text and context and returns `{:error, :outdated}` when it cannot. Wiring it into `append_patchset` is open work; see the tracker. Token-range anchors can be written but not relocated; keep the `"token_range"` stub.
- Code storage uses code.storage (Pierre) only; no local git adapter. It is optional, enabled by `CODE_STORAGE_*` env vars (see README).
- CLI config lives in `~/.config/reviews/`.
- Package manager for `assets/` is Bun; `bun.lock` is canonical. `package-lock.json` is a leftover.
- Dependency updates respect a 7-day release-age rule (the org `.npmrc` enforces it for npm; apply the same to Hex and Docker tags).

## Conventions

- Plain English in UI copy, CLI output, errors, commit messages and PR text: short sentences that say what happened and what to do.
- `current_user` is set by `ReviewsWeb.Plugs.FetchCurrentUser` and re-derived in LiveView `mount/3`; API controllers take `current_identity`.
- Colocated hooks (`.HookName`) for template-local JS; `assets/js/hooks/` for shared hooks registered in `app.js`. A hook that owns its DOM needs `phx-update="ignore"`.
- `:key` on every `:for`. `JSON` (built in), not Jason.
- Keep `review_live.ex` and `packet_components.ex` changes small and focused; they are the most contended files.
- Tests: context tests under `test/reviews/`, LiveView tests under `test/reviews_web/live/`, controller tests under `test/reviews_web/controllers/api/`. Test through element IDs, not raw HTML.

## Working as an agent here

- Commits are GPG-signed with the maintainer's smartcard. If signing fails, leave the work staged and hand back the exact `git commit` command. Never disable signing.
- Push only to `origin`, only your own branches. Open PRs as drafts. Never push to a contributor's branch; stack your own branch on top instead.
- For parallel work use `git worktree add .claude/worktrees/<name> -b <branch> origin/main` and `MIX_TEST_PARTITION=<name>` for tests. Remove the worktree after merge.
- Postgres in dev may be socket-only (`/tmp/.s.PGSQL.5432`); if `pg_isready` fails on TCP, try `pg_isready -h /tmp`.
- `.claude/` is per-checkout state and gitignored, except `.claude/rules/`.

## Deferred

- Syntax highlighting worker pool for Pierre/Shiki.
- CSP headers.
- Phoenix base-path support (`.plans/phoenix-base-path-support.md`), until a deployment needs it.
