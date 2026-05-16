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

Preview apps share a single Postgres database. This is the simple v1
trade-off: data leaks across previews, and a migration in one PR can
affect a preview running on another PR. For a tool with link-based,
ephemeral data this is acceptable; per-PR databases are a worthwhile
follow-up.

Either provision a new cluster (`fly postgres create --name
reviews-preview-pg --region sjc`) or reuse the prod cluster with a
**separate database name** so prod data isn't touched:

```sh
fly postgres connect -a reviews-dev-pg <<'SQL'
CREATE DATABASE reviews_preview;
SQL
```

Grab the connection URL — that goes into `PREVIEW_DATABASE_URL` below.

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
| `PREVIEW_DATABASE_URL`          | Full `postgres://...` URL for the shared preview DB   |
| `PREVIEW_GITHUB_CLIENT_ID`      | _(optional — leave unset to skip OAuth on previews)_  |
| `PREVIEW_GITHUB_CLIENT_SECRET`  | _(optional — leave unset to skip OAuth on previews)_  |

---

## How a PR flows through

1. **PR opened** by a maintainer/collaborator → workflow fires →
   if a `preview` Environment with required reviewers is configured,
   waits for approval → `superfly/fly-pr-review-apps` creates app
   `reviews-pr-<N>`, sets secrets, and runs `fly deploy`. The release
   command in `fly.toml` runs migrations against the shared preview DB.

2. **Subsequent pushes** → workflow re-runs → app redeploys with the
   new HEAD.

3. **PR closed (merged or not)** → workflow fires the close path →
   `superfly/fly-pr-review-apps` destroys the Fly app.

---

## Tearing it down manually

If a preview app gets stuck or the close workflow didn't run:

```sh
fly apps destroy reviews-pr-42
```

---

## Known limitations

- **OAuth doesn't work on previews** unless you set up a proxy or per-PR
  apps. See "GitHub OAuth app for previews" above.
- **No custom domain.** Previews live at `reviews-pr-<N>.fly.dev` only.
- **Shared database.** All previews share one Postgres DB; migrations
  and data are not isolated. Per-PR databases are a worthwhile
  follow-up but require automation for `CREATE DATABASE` / `DROP
  DATABASE` and routing the per-PR DB name into each app's
  `DATABASE_URL`.
- **Cost.** Each preview app is a 1GB/1vCPU machine that auto-stops when
  idle (`auto_stop_machines = 'stop'`, inherited from `fly.toml`).
  Idle cost is near zero; an active preview is roughly the same as the
  prod machine.
