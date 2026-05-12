# Release & deployment

This doc covers everything you need to ship Reviews to production: the prod
GitHub OAuth app, the Fly deploy, the GitHub mirror, and the CI/CD pipeline that
auto-deploys `main`.

The currently-deployed prod app is **`reviews-dev`** on Fly (`reviews-dev.fly.dev`).
The name has `-dev` for historical reasons; treat it as production.

---

## 1. Prerequisites

You need (one-time):

- A Fly account with the `flyctl` CLI authenticated (`fly auth login`).
- Admin access to a GitHub organization (or your personal account) that will
  host the public mirror and run Actions.
- Access to create GitHub OAuth Apps under that same org/user.

---

## 2. Create the production GitHub OAuth App

The local-dev OAuth app (the one whose credentials live in `.env.local`) points
its callback at `http://localhost:4000/auth/github/callback`, which won't work
for the deployed instance. Make a **separate** OAuth app for production — never
share client secrets across environments.

### Steps

1. Go to **GitHub → Settings → Developer settings → OAuth Apps → New OAuth App**
   (or, for an org, **Org settings → Developer settings → OAuth Apps**).
2. Fill in:
   - **Application name:** `Reviews (prod)` — or whatever name you want users
     to see on the consent screen.
   - **Homepage URL:** `https://reviews-dev.fly.dev`
   - **Application description:** _(optional)_ "Code review tool for arbitrary
     diffs."
   - **Authorization callback URL:** `https://reviews-dev.fly.dev/auth/github/callback`
     — exact path matters; this is the route registered at
     `lib/reviews_web/router.ex:35`.
3. **Register application**. Copy the **Client ID**.
4. **Generate a new client secret**. Copy it — you only see it once.

### Push the credentials to Fly

```sh
fly secrets set \
  GITHUB_CLIENT_ID=<paste-client-id> \
  GITHUB_CLIENT_SECRET=<paste-client-secret> \
  -a reviews-dev
```

Fly will restart the app. Confirm it came up:

```sh
fly status -a reviews-dev
curl -sI https://reviews-dev.fly.dev/ | head -1   # expect: HTTP/2 200
```

### Smoke-test the flow

1. Open `https://reviews-dev.fly.dev/auth/github` in an incognito window.
2. Authorize the app.
3. You should land back on the site, signed in. Navigate to `/settings` —
   you'll see a "Mint API token" control. Mint one to use with the CLI:

   ```sh
   reviews login
   # server_url: https://reviews-dev.fly.dev
   # api_token:  <paste from /settings>
   ```

4. Test a push from any git checkout:

   ```sh
   cd ~/some-repo
   reviews push --title "test review"
   ```

   It should print a `https://reviews-dev.fly.dev/r/<slug>` URL.

---

## 3. Other required Fly secrets

Beyond the GitHub OAuth pair, the app needs:

| Secret             | How to generate                                       | Notes                                                                 |
| ------------------ | ----------------------------------------------------- | --------------------------------------------------------------------- |
| `SECRET_KEY_BASE`  | `mix phx.gen.secret`                                  | 64-byte random hex. Phoenix raises at boot if unset.                  |
| `DATABASE_URL`     | Provisioned automatically by `fly postgres attach`    | `ecto://user:pass@host/db` format.                                    |
| `PHX_HOST`         | Already set in `fly.toml` (`reviews-dev.fly.dev`)     | Change here, not as a secret, if you move to a custom domain.         |

To set the secret-class entries:

```sh
fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret) -a reviews-dev
```

`DATABASE_URL` is populated by `fly postgres attach <pg-app> -a reviews-dev`;
don't set it manually unless you're pointing at an external Postgres.

To list what's currently set (names only; values aren't readable):

```sh
fly secrets list -a reviews-dev
```

---

## 4. Mirror the repo to GitHub

Origin stays at the private soft-serve (`ssh://git.internal/reviews.git`). We
add GitHub as a one-way push mirror so Actions can run on it.

### One-time setup

1. Create an **empty** public (or private) repo on GitHub:
   `https://github.com/<owner>/reviews`. Do **not** initialize it with a README
   — it must be empty so the first mirror push works.

2. Add the GitHub URL as a second remote, locally:

   ```sh
   git remote add github git@github.com:<owner>/reviews.git
   ```

3. Push everything once, by hand, to seed it:

   ```sh
   git push github main
   git push github --tags
   ```

### Keep it in sync

Two options — pick whichever fits your workflow:

**A. Manual `push` on release.** When you want CI to run, do:

```sh
git push origin main          # canonical, to soft-serve
git push github main          # mirror, triggers Actions + deploy
```

**B. Soft-serve `post-receive` hook.** On the soft-serve host, add a hook that
runs after every push to `main`:

```sh
# In the bare repo on tinycube-server:
cat > hooks/post-receive <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while read oldrev newrev refname; do
  if [ "$refname" = "refs/heads/main" ]; then
    git push github "$newrev:refs/heads/main"
  fi
done
EOF
chmod +x hooks/post-receive
```

(Option B requires the soft-serve box to have a deploy-key with push access to
the GitHub repo. Out of scope for this doc — set up an SSH key in
`~/.ssh/config` aliased for `github.com` and add the pubkey as a deploy key
with write access to the mirror repo.)

---

## 5. GitHub Actions: test + deploy

The workflow at `.github/workflows/ci.yml` runs on every push and PR:

- `mix format --check-formatted`
- `mix compile --warnings-as-errors`
- `mix test` (against an ephemeral Postgres service container)

On push to `main` only, after tests pass, it runs `flyctl deploy -a reviews-dev`.

### Required GitHub repo secrets

Set under **Repo → Settings → Secrets and variables → Actions → New repository
secret**:

| Secret          | How to get it                                              |
| --------------- | ---------------------------------------------------------- |
| `FLY_API_TOKEN` | `fly auth token` — paste the output. Rotate periodically.  |

That's it. The deploy job uses `superfly/flyctl-actions/setup-flyctl` and reads
`FLY_API_TOKEN` from the env to authenticate.

### What the deploy job does

1. Builds the Docker image remotely on Fly's builders (no local docker needed).
2. Runs the `release_command` in `fly.toml` (`/app/bin/migrate`), which
   executes Ecto migrations against the attached Postgres.
3. Rolls the machines.

Migration failures abort the deploy; the previous version keeps serving
traffic.

---

## 6. Manual deploy (escape hatch)

If CI is wedged or you need to push a hotfix from your laptop:

```sh
fly deploy -a reviews-dev
```

`fly deploy` reads `fly.toml` from the repo root, builds the Dockerfile, runs
the release command, and rolls the machines. It's the same thing CI does — CI
just runs it from a clean checkout with the API token.

---

## 7. Rollback

```sh
fly releases -a reviews-dev               # find the release you want
fly releases rollback <version> -a reviews-dev
```

This reverts the machine image but **does not** revert database migrations.
If the bad release included a migration that's destructive to roll back, you
need to ship a forward-fix migration instead — don't roll back blindly.

---

## 8. Custom domain (when ready)

Pointing `reviews.yourdomain.com` at the Fly app:

1. `fly certs add reviews.yourdomain.com -a reviews-dev`
2. Add the DNS records Fly prints (an `A`/`AAAA` pair, or a `CNAME`).
3. Update `fly.toml`: change `PHX_HOST = 'reviews.yourdomain.com'`.
4. Update the GitHub OAuth App's **Homepage URL** and
   **Authorization callback URL** to the new domain.
5. `fly deploy -a reviews-dev` to pick up the new `PHX_HOST`.

Until step 4, OAuth sign-ins from the new domain will fail with a callback
mismatch error.

---

## 9. Troubleshooting

**Deploy build fails at `mix assets.deploy` with `Could not resolve "phoenix-colocated/reviews"`:**
The Dockerfile must run `mix compile` _before_ `mix assets.deploy` so
LiveView's colocated-hook extractor populates
`_build/prod/lib/phoenix_live_view/priv/static/phoenix-colocated/reviews/`.
Check the order in `Dockerfile`.

**OAuth callback returns `redirect_uri_mismatch`:**
The callback URL in the GitHub OAuth App settings doesn't match the URL the
app is generating. Check:
- `PHX_HOST` in `fly.toml`
- GitHub OAuth App **Authorization callback URL**
- They must agree, exactly, including scheme (`https://`) and the
  `/auth/github/callback` path.

**`reviews push` returns 401:**
Your API token is wrong, expired, or revoked. Re-mint at
`https://reviews-dev.fly.dev/settings`, then `reviews login` again.

**Fly deploy succeeds but app boots-and-dies:**
Likely a missing required env (`SECRET_KEY_BASE`, `DATABASE_URL`). Check
`fly logs -a reviews-dev` — `runtime.exs` raises a clear message naming the
missing var.
