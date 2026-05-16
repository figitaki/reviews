# Preview environments

Every pull request opened by a maintainer or collaborator gets its own
Fly app — `reviews-pr-<number>.fly.dev` — built from the PR's HEAD and
backed by a per-PR Postgres database. The app is created on open,
re-deployed on every push, and destroyed when the PR closes.

This follows the pattern in
[Fly's review-apps blueprint](https://fly.io/docs/blueprints/review-apps-guide/),
using the `superfly/fly-pr-review-apps` Action to manage the app
lifecycle. Workflow lives at `.github/workflows/fly-review.yml`.

The production deploy from `main` (in `.github/workflows/ci.yml`) is
unaffected — preview envs are a separate workflow with their own
secrets, environment, and Postgres database.

---

## Who can trigger a preview deploy

Only **contributors with write access** to the repo can trigger a
preview deploy. The workflow enforces this in two layers:

1. **Static gate in the workflow.** The job's `if:` clause requires:
   - the PR head branch lives in this repo (no forks), and
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

If you only want one of these, layer (1) is the stronger default —
it stops fork PRs from running the workflow at all. Layer (2) protects
against the case where a maintainer pushes to a branch a contributor
opened (the `author_association` then reflects the PR opener, not the
pusher).

---

## One-time setup

### 1. GitHub Environment

Create an Environment named `preview` (Settings → Environments → New
environment). Optionally configure required reviewers under "Deployment
protection rules".

### 2. Fly Postgres cluster for previews

Pick **one** of the following:

**Option A (recommended): a dedicated cluster for previews.**

```sh
fly postgres create --name reviews-preview-pg --region sjc
```

Migrations on a preview can't destabilise prod data, and you can size
the cluster down to save money.

**Option B: reuse the production cluster.** Cheaper, but a runaway
migration in a preview app can lock prod tables. Only do this if you're
sure preview migrations are isolated to per-PR databases.

In either case, grab the cluster's internal connection string:

```sh
fly postgres connect -a reviews-preview-pg
# inside psql:
\conninfo
# Take the host/port/user/password — you want a URL like:
# postgres://postgres:<pw>@reviews-preview-pg.internal:5432
```

That **base** URL (without a trailing `/<database>` segment) goes into
`PREVIEW_DATABASE_URL_BASE` below. The workflow appends
`/reviews_pr_<N>` per PR.

### 3. GitHub OAuth app for previews

Preview apps live at unique hostnames (`reviews-pr-42.fly.dev` etc.),
and GitHub OAuth callback URLs must match the host exactly. There's no
clean way to share one OAuth app across every preview hostname.

Two practical options:

- **Skip OAuth on previews.** The app supports anonymous viewing of
  reviews (link-based sharing is the v1 model). Commenting requires
  sign-in and will fail on previews. For most "show me what this PR
  looks like" use cases this is fine — leave
  `PREVIEW_GITHUB_CLIENT_ID` / `PREVIEW_GITHUB_CLIENT_SECRET` unset and
  the runtime config will fall through to `nil` (OAuth will just be
  broken on previews, not the rest of the app).

- **Use a single OAuth app pointing at the prod hostname** as a
  redirect proxy. Out of scope here; involves a tiny route on prod
  that bounces sign-ins back to the preview host. File an issue if you
  want this.

### 4. Repo secrets and variables

Under **Settings → Secrets and variables → Actions**:

**Repository variables** (visible, non-sensitive):

| Variable           | Value                                  |
| ------------------ | -------------------------------------- |
| `FLY_ORG`          | Your Fly organization slug             |
| `FLY_POSTGRES_APP` | e.g. `reviews-preview-pg`              |

**Repository secrets** (encrypted):

| Secret                          | Value                                                 |
| ------------------------------- | ----------------------------------------------------- |
| `FLY_API_TOKEN`                 | Same token as production CI (`fly auth token`)        |
| `PREVIEW_SECRET_KEY_BASE`       | Output of `mix phx.gen.secret`                        |
| `PREVIEW_DATABASE_URL_BASE`     | `postgres://...@reviews-preview-pg.internal:5432` (no trailing DB name) |
| `PREVIEW_GITHUB_CLIENT_ID`      | _(optional — leave unset to skip OAuth on previews)_  |
| `PREVIEW_GITHUB_CLIENT_SECRET`  | _(optional — leave unset to skip OAuth on previews)_  |

---

## How a PR flows through

1. **PR opened** by a maintainer/collaborator → workflow fires →
   if a `preview` Environment with required reviewers is configured,
   waits for approval → `flyctl postgres connect` creates
   `reviews_pr_<N>` → `superfly/fly-pr-review-apps` creates app
   `reviews-pr-<N>`, sets secrets (including
   `DATABASE_URL=.../reviews_pr_<N>`), and runs `fly deploy`. The
   release command in `fly.toml` runs migrations against the fresh DB.

2. **Subsequent pushes** → workflow re-runs → `CREATE DATABASE` swallows
   its "already exists" error → app redeploys with the new HEAD.

3. **PR closed (merged or not)** → workflow fires the close path →
   `superfly/fly-pr-review-apps` destroys the Fly app → we drop the
   per-PR database.

---

## Tearing it down manually

If a preview app gets stuck or the close workflow didn't run:

```sh
fly apps destroy reviews-pr-42
fly postgres connect -a reviews-preview-pg <<'SQL'
DROP DATABASE IF EXISTS reviews_pr_42;
SQL
```

---

## Known limitations

- **OAuth doesn't work on previews** unless you set up a proxy or per-PR
  apps. See "GitHub OAuth app for previews" above.
- **No custom domain.** Previews live at `reviews-pr-<N>.fly.dev` only.
- **Cost.** Each preview app is a 1GB/1vCPU machine that auto-stops when
  idle (`auto_stop_machines = 'stop'`, inherited from `fly.toml`).
  Idle cost is near zero; an active preview is roughly the same as the
  prod machine. Per-PR DBs are tiny (empty until you push diffs) but
  they do accumulate WAL if not dropped — close PRs to clean up.
