# Preview environments

Every pull request opened by a maintainer or collaborator gets its own
Fly app — `reviews-pr-<number>.fly.dev` — built from the PR's HEAD. The
app is created on open, re-deployed on every push, and destroyed when
the PR closes.

This follows the pattern in
[Fly's review-apps blueprint](https://fly.io/docs/blueprints/review-apps-guide/),
driving `flyctl` directly (`apps create` → `secrets set --stage` →
`deploy --remote-only` → `apps destroy`). Workflow lives at
`.github/workflows/fly-review.yml`.

The official `superfly/fly-pr-review-apps` action is intentionally
**not** used: it calls `flyctl launch --copy-config` unconditionally
inside a Docker container, which runs Phoenix scanners that need
`mix` in the container's PATH — which it isn't, and we can't add it
from the host. Direct `flyctl` calls skip the launch path entirely.

The production deploy from `main` (in `.github/workflows/ci.yml`) is
unaffected — preview envs are a separate workflow with their own
secrets and environment.

## Self-disabling until configured

The workflow's job has an `if: vars.FLY_ORG != ''` gate. **Until you set
that repo variable**, the Preview job is skipped on every PR — no red
checks, no noise. Once `FLY_ORG` is set, future PRs from collaborators
will start triggering deploys.

---

## Who can trigger a preview deploy

Only **contributors with write access** to the repo can trigger a
preview deploy. The workflow enforces this in two layers:

1. **Static gate in the workflow.** The job's `if:` clause requires:
   - `vars.FLY_ORG` is set (one-time setup complete);
   - the PR head branch lives in this repo (no forks); and
   - `github.event.pull_request.author_association` is `OWNER`,
     `MEMBER`, or `COLLABORATOR`.

   `CONTRIBUTOR` and `FIRST_TIME_CONTRIBUTOR` are deliberately excluded
   — those mean "has merged commits in the past", not "has write
   access".

2. **GitHub Environment with required reviewers.** The job targets
   the `preview` GitHub Environment. If you add required reviewers to
   that environment (repo Settings → Environments → preview → Required
   reviewers), the deploy step will pause until a maintainer clicks
   "Approve" in the Actions UI.

Layer (1) stops fork PRs from running the workflow at all. Layer (2)
protects against the case where a maintainer pushes to a branch a
contributor opened (the `author_association` then reflects the PR
opener, not the pusher).

---

## One-time setup

### 1. GitHub Environment

Create an Environment named `preview` (Settings → Environments → New
environment). Optionally configure required reviewers under "Deployment
protection rules".

### 2. Fly Postgres for previews

All preview apps use one Postgres server, but each preview app has its
own database on it: `reviews_pr_<N>`. See "Per-PR databases" below.

Either provision a new cluster (`fly postgres create --name
reviews-preview-pg --region sjc`) or reuse the prod cluster. Prod data
is not touched: previews only create, use and drop `reviews_pr_<N>`
databases.

`PREVIEW_DATABASE_URL` gives the server and the credentials. The
database name in its path does not matter, because the workflow
replaces it with `reviews_pr_<N>`. The user in the URL must be able to
create databases (`CREATEDB` or superuser). To give an existing user
that permission:

```sh
fly postgres connect -a reviews-dev-pg <<'SQL'
ALTER ROLE <preview_user> CREATEDB;
SQL
```

The server must also have a `postgres` database (Fly Postgres has one).
The release command connects to it to run `CREATE DATABASE`.

### 3. GitHub OAuth app for previews

Preview apps live at unique hostnames (`reviews-pr-42.fly.dev` etc.),
and GitHub OAuth callback URLs must match the host exactly. There's no
clean way to share one OAuth app across every preview hostname.

The pragmatic answer: leave `PREVIEW_GITHUB_CLIENT_ID` /
`PREVIEW_GITHUB_CLIENT_SECRET` unset. The app supports anonymous
viewing of reviews (link-based sharing is the v1 model). Commenting
requires sign-in and will fail on previews. For most "show me what
this PR looks like" use cases this is fine.

### 4. Repo secrets and variables

Under **Settings → Secrets and variables → Actions**:

**Repository variables** (visible, non-sensitive):

| Variable    | Value                            |
| ----------- | -------------------------------- |
| `FLY_ORG`   | Your Fly organization slug. **This variable is the on/off switch — the workflow is skipped until it's set.** |

**Repository secrets** (encrypted):

| Secret                          | Value                                                 |
| ------------------------------- | ----------------------------------------------------- |
| `FLY_API_TOKEN`                 | Same token as production CI (`fly auth token`)        |
| `PREVIEW_SECRET_KEY_BASE`       | Output of `mix phx.gen.secret`                        |
| `PREVIEW_DATABASE_URL`          | Full `postgres://...` URL for the preview Postgres server. The workflow replaces the database name with `reviews_pr_<N>`. |
| `PREVIEW_API_TOKEN`             | A bearer token of your choice (e.g. `rev_$(openssl rand -hex 24)`). Used to bootstrap a synthetic "preview" user — see "Pushing diffs to a preview" below. |
| `PREVIEW_GITHUB_CLIENT_ID`      | _(optional — leave unset to skip OAuth on previews)_  |
| `PREVIEW_GITHUB_CLIENT_SECRET`  | _(optional — leave unset to skip OAuth on previews)_  |

---

## Pushing diffs to a preview

GitHub OAuth doesn't work on per-PR hostnames, so there's no UI path to
mint an API token on a preview app. Instead, every preview boots with
a synthetic `preview` user seeded by
`Reviews.Release.seed_preview_user/0`, with an API token derived from
the `PREVIEW_API_TOKEN` secret above.

To use it:

```sh
reviews login
# server_url: https://reviews-pr-42.fly.dev
# api_token:  <the same string you put in PREVIEW_API_TOKEN>

reviews push
```

The seeding step is a no-op in production (the prod app has no
`PREVIEW_API_TOKEN` env var), so the synthetic user only exists on
previews.

---

## Per-PR databases

Each preview app `reviews-pr-<N>` uses its own database,
`reviews_pr_<N>`, on the preview Postgres server.

**Why.** On 2026-10-09, 14 PRs had previews deployed at the same time,
and all of them used one shared database. Two problems occurred:

- The preview Postgres pooler refused new connections with
  `FATAL 08P01 no more connections allowed (max_client_conn)`. Each
  app opened 10 connections (the default pool), and 14 apps used more
  than the cap. Four release commands failed with "Could not create
  schema migrations table", and every page that used the database
  returned 500 on every preview. The fix for this is in "Connection
  budget" below, not the per-PR database.
- Three branches with migrations ran `ALTER TABLE` on the shared
  database. After that, every preview app that was already running
  returned 500 on review pages, because its open connections had
  cached query plans for the old tables. The 500s stopped only when
  each app was deployed again.

With one database per app, a migration in one PR changes only that
PR's database. A per-PR database does not reduce the number of
connections to the server. See "Connection budget" below.

**How the database is created.**

1. The "Stage secrets" step in `.github/workflows/fly-review.yml` sets
   these secrets on the app:
   - `PREVIEW_DB_NAME=reviews_pr_<N>`. The step stops if the name does
     not match `reviews_pr_<digits>`.
   - `DATABASE_URL`: `PREVIEW_DATABASE_URL` with its path replaced by
     `/reviews_pr_<N>`.
2. The release command (`/app/bin/migrate`) runs
   `Reviews.Release.ensure_database/0` first. It connects to the
   `postgres` maintenance database with the same credentials and runs
   `CREATE DATABASE reviews_pr_<N>` if the database does not exist.
   Then it runs migrations and seeds as before.

`ensure_database/0` does nothing when `PREVIEW_DB_NAME` is not set, so
prod is not affected. When `PREVIEW_DB_NAME` is set, it stops with an
error if the name is not `reviews_pr_<digits>`, or if `DATABASE_URL`
names a different database. This prevents a preview from migrating a
database that it does not own.

**How the database is dropped.** When the PR closes, the "Drop preview
database" step runs before "Destroy preview app":

1. It sends one HTTP request to the app, so that Fly starts a stopped
   machine.
2. It runs this command in the app, up to five times:

   ```sh
   flyctl ssh console --app reviews-pr-<N> \
     -C "/app/bin/reviews eval Reviews.Release.drop_preview_database"
   ```

   `drop_preview_database/0` runs `DROP DATABASE ... WITH (FORCE)`, which
   also closes the app's open connections. It uses the same checks as
   `ensure_database/0`, so it drops only `reviews_pr_<digits>`, and only
   the database that the app's own `DATABASE_URL` names.

The drop step is best effort (`continue-on-error: true`). If it fails,
the app is still destroyed, and the run shows a warning.

**If a drop fails.** Drop the database by hand. Do this only for a PR
that is closed:

```sh
fly postgres connect -a reviews-dev-pg <<'SQL'
DROP DATABASE IF EXISTS reviews_pr_42 WITH (FORCE);
SQL
```

To find databases that were not dropped, list them and compare with
the open PRs:

```sh
fly postgres connect -a reviews-dev-pg <<'SQL'
SELECT datname FROM pg_database WHERE datname LIKE 'reviews_pr_%';
SQL
```

Apps that were deployed before this change have no `PREVIEW_DB_NAME`
and use the old shared database. When such a PR closes, the drop step
does nothing. On the next push, the app moves to its own database,
which starts empty except for the demo review and the preview user.

---

## Connection budget

All previews connect to one Postgres server through a pooler that
accepts at most `max_client_conn` client connections. Previews deploy
with `fly.preview.toml` (not `fly.toml`) to stay under that cap:

| Setting | Value | Effect |
| ------- | ----- | ------ |
| `POOL_SIZE` (in `[env]`) | `2` | A running preview machine holds 2 connections. Prod uses 10. |
| `--ha=false` and `flyctl scale count 1` | 1 machine | One machine per preview, not two. |
| `auto_stop_machines = 'stop'`, `min_machines_running = 0` | | Fly stops an idle machine after a few minutes. A stopped machine holds 0 connections. The next request starts it again. |
| Release command pool | 2 | Migrations use a pool of 2, and the seeds use 1. The steps run one after the other. |

Connections for one preview:

- Stopped (idle): 0.
- Running: 2.
- During a deploy: up to 4, because the release command (2) runs while
  the old machine (2) is still up.

So the cap carries about `max_client_conn / 2` running previews, or
`max_client_conn / 4` previews that all deploy at the same time. Keep
some room for other clients and for `fly postgres connect`. For
example, with `max_client_conn = 100` (the pgbouncer default), 14
running previews use 28 connections, and 14 deploying at once use 56.
Before this change, 14 previews used 140 or more.

A browser tab with a review page open keeps a LiveView websocket open,
so the machine does not go idle until the tab closes.

**When the cap is hit** (`no more connections allowed
(max_client_conn)` in the app or release logs):

1. Stop idle preview machines. They start again on the next request:

   ```sh
   fly apps list | grep reviews-pr-
   fly machine list --app reviews-pr-42
   fly machine stop <machine-id> --app reviews-pr-42
   ```

2. Close stale PRs. The close workflow drops the database and destroys
   the app. For a PR that is already closed, see "Tearing it down
   manually".
3. Lower `POOL_SIZE` in `fly.preview.toml` to `1`. It takes effect on
   each preview's next deploy.
4. If the server allows it, raise `max_client_conn` on the pooler.

---

## How a PR flows through

1. **PR opened** by a maintainer/collaborator → workflow fires →
   if a `preview` Environment with required reviewers is configured,
   waits for approval → `flyctl apps create` makes `reviews-pr-<N>`,
   `flyctl secrets set --stage` writes config, and `flyctl deploy
   --remote-only` builds the image on Fly's builders. The release
   command in `fly.preview.toml` creates the `reviews_pr_<N>` database if
   needed, runs migrations and seeds the preview user.

2. **Subsequent pushes** → workflow re-runs → app redeploys with the
   new HEAD.

3. **PR closed (merged or not)** → workflow fires the close path →
   the `reviews_pr_<N>` database is dropped (best effort), then
   `flyctl apps destroy` removes the Fly app.

---

## Tearing it down manually

If a preview app gets stuck or the close workflow didn't run:

```sh
fly apps destroy reviews-pr-42
```

Then drop its database by hand, as in "If a drop fails" above.

---

## Known limitations

- **OAuth doesn't work on previews** unless you set up a proxy or per-PR
  apps. See "GitHub OAuth app for previews" above.
- **No custom domain.** Previews live at `reviews-pr-<N>.fly.dev` only.
- **Shared Postgres server.** Each preview has its own database, but
  all previews use one server. They share its connection limit, CPU
  and memory. See "Connection budget".
- **Cost.** Each preview app is a 1GB/1vCPU machine that auto-stops when
  idle (`auto_stop_machines = 'stop'` in `fly.preview.toml`).
  Idle cost is near zero; an active preview is roughly the same as the
  prod machine.
