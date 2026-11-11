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

2. **GitHub Environment with required reviewers and secrets.** The job targets
   the `preview` GitHub Environment. Store all preview credentials there, not
   as repository secrets, and require maintainer review before deployment.
   Review the PR code and workflow before approving: the approved code runs
   with preview credentials. Removing `environment` from a PR-editable workflow
   must not make deployment credentials available.

Layer (1) stops fork PRs from running the workflow at all. Layer (2)
protects against the case where a maintainer pushes to a branch a
contributor opened (the `author_association` then reflects the PR
opener, not the pusher).

---

## One-time setup

### 1. GitHub Environment

Create an Environment named `preview` (Settings → Environments → New
environment). Configure required maintainer reviewers under "Deployment
protection rules" and disable administrator bypass. Production uses a separate
`production` environment restricted to the `main` branch, with an app-scoped
Fly token. Never expose the production token to previews. If preview automation
needs an organization-scoped token to create apps, a separate Fly organization
is the strongest isolation boundary; reviewer gating does not narrow its scope.

### 2. Fly Postgres for previews

All preview apps use one Postgres server, but each preview app has its
own database on it: `reviews_pr_<N>`. See "Per-PR databases" below.

Provision a dedicated preview cluster (`fly postgres create --name
reviews-preview-pg --region sjc`). Do not reuse the production cluster
or its credentials. Per-PR database names isolate schema changes, not
privileges: approved preview code receives the database credentials,
and a shared owner role can read or drop other previews' databases.
Use only synthetic data in previews.

`PREVIEW_DATABASE_URL` gives the server and the credentials. The
database name in its path does not matter, because the workflow
replaces it with `reviews_pr_<N>`. The user in the URL must be able to
create databases. Use a dedicated preview role with `CREATEDB`, not
superuser or role-administration privileges. To configure that role
on the preview cluster:

```sh
fly postgres connect -a reviews-preview-pg <<'SQL'
ALTER ROLE <preview_user> NOSUPERUSER NOCREATEROLE CREATEDB;
SQL
```

The server must also have a `postgres` database (Fly Postgres has one).
The release command connects to it to run `CREATE DATABASE`.

If a pooler such as PgBouncer sits in front of the server, it must
accept connections for any database name, or at least for `postgres`
and every `reviews_pr_<N>`. A pooler that lists only one database
refuses the new connections, and the release command fails.

The close workflow connects through `flyctl proxy` to the host and port
in `PREVIEW_DATABASE_URL`, using the `FLY_ORG` private network. The preview
Fly token must permit that proxy connection to the database endpoint,
as well as app creation/destruction. Prefer a direct Postgres endpoint
if the pooler cannot expose the maintenance database. Before enabling
the workflow, verify create/drop with the preview role on this endpoint;
neither role permissions nor pooler routing are inferred from the URL.
The endpoint must be on the preview organization's default private network;
custom networks and public database endpoints are not supported by this
proxy path. Check `fly wireguard list` after the first close: fresh CI runners
may leave WireGuard peers that need separate retirement.

### 3. GitHub OAuth app for previews

Preview apps live at unique hostnames (`reviews-pr-42.fly.dev` etc.),
and GitHub OAuth callback URLs must match the host exactly. There's no
clean way to share one OAuth app across every preview hostname.

The pragmatic answer: leave `PREVIEW_GITHUB_CLIENT_ID` /
`PREVIEW_GITHUB_CLIENT_SECRET` unset. The app supports anonymous
viewing of reviews (link-based sharing is the v1 model). Commenting
requires sign-in and will fail on previews. For most "show me what
this PR looks like" use cases this is fine.

### 4. Environment secrets and repository variables

Under **Settings → Secrets and variables → Actions**:

**Repository variables** (visible, non-sensitive):

| Variable    | Value                            |
| ----------- | -------------------------------- |
| `FLY_ORG`   | Your Fly organization slug. **This variable is the on/off switch — the workflow is skipped until it's set.** |

**`preview` environment secrets** (encrypted; do not duplicate at repository scope):

| Secret                          | Value                                                 |
| ------------------------------- | ----------------------------------------------------- |
| `FLY_API_TOKEN`                 | Dedicated, expiring preview deploy token; never the production token |
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
previews. Changing this token replaces prior named preview-bootstrap tokens
when the updated seed runs; unrelated user tokens are preserved.

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

**How the database is dropped.** When the PR closes, the runner executes
`.github/scripts/cleanup_preview.py`:

1. Validate that the app and database names identify the same PR.
2. List apps in `FLY_ORG` and destroy this preview if it exists. A failed
   list or destroy stops cleanup rather than guessing that the app is gone.
3. Open a private `flyctl proxy` to the database endpoint. Connect to
   `postgres` with the preview credentials, then run
   `DROP DATABASE IF EXISTS "reviews_pr_<N>" WITH (FORCE)`.

Cleanup does not need a healthy app, an SSH session, or a particular
release version. An already-deleted app can still have its orphan database
removed. A missing database is harmless. Credentials stay in the child
environment, not command arguments; connection errors are not echoed.

Database cleanup failure fails the job, after app destruction. The whole
step has an eight-minute limit. Follow the manual runbook on failure.
Per-PR workflow runs are serialized without cancelling an in-flight deploy,
so a close event waits for that deploy before destroying its machines.
The close job still requires preview-environment approval. If an older
deploy is waiting for approval after its PR closes, reject that deployment
so it cannot block the queued close run; then approve cleanup itself.

**If a drop fails.** Drop the database by hand. Do this only for a PR
that is closed:

```sh
fly postgres connect -a reviews-preview-pg <<'SQL'
DROP DATABASE IF EXISTS reviews_pr_42 WITH (FORCE);
SQL
```

To find databases that were not dropped, list them and compare with
the open PRs. Include PRs closed with merge conflicts, since GitHub may not
start their close workflow at all:

```sh
fly postgres connect -a reviews-preview-pg <<'SQL'
SELECT datname FROM pg_database WHERE datname LIKE 'reviews_pr_%';
SQL
```

Apps deployed before this change use the old shared database. Closing
one still destroys the app and attempts to drop only its per-PR database
(which may not exist); it never drops the shared database. On the next
push, the app moves to its own database, initially containing only the
demo review and preview user. Once all old apps have moved or closed,
retire the old shared database separately after confirming it is unused.

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

Existing deployments keep their old pool sizes and machine counts until
redeployed. As part of rollout, redeploy open previews or stop obsolete
ones; merging this workflow alone does not reduce existing connections.

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

2. Close stale PRs. The close workflow destroys the app, then drops
   its database. For a PR that is already closed, see "Tearing it down
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
   the app is destroyed, then the runner drops `reviews_pr_<N>` through
   a private database proxy. Database cleanup failure fails the run.

---

## Tearing it down manually

If a preview app gets stuck or the close workflow didn't run:

- GitHub [does not run `pull_request` workflows for conflicted
  PRs](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request).
  A closed, unmerged PR with conflicts can therefore leave both resources
  behind with no failed cleanup job. Check its app and database manually.
- Reject any outstanding deployment approval for a closed PR before manual
  teardown, and ensure no deployment remains in progress. Cleanup jobs also
  wait for required approval; an unapproved close job has removed nothing.

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
