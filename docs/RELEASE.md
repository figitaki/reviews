# Release & deployment

This doc covers everything you need to ship Reviews to production: the prod
GitHub OAuth app, the Fly deploy, the GitHub mirror, and the CI/CD pipeline that
auto-deploys `main`.

The currently-deployed prod app is **`reviews-dev`** on Fly, served at the
custom domain **`reviews.figitaki.dev`**. The Fly app name keeps the `-dev`
suffix for historical reasons; treat it as production. The legacy Fly hostname
`reviews-dev.fly.dev` still resolves but 301-redirects to the custom domain via
`ReviewsWeb.Plugs.CanonicalHost`.

For per-PR preview environments (a separate workflow that deploys
`reviews-pr-<number>.fly.dev` apps), see [`PREVIEW_ENVS.md`](PREVIEW_ENVS.md).

---

## 1. Prerequisites

You need (one-time):

- A Fly account with the `flyctl` CLI authenticated (`fly auth login`).
- Admin access to a GitHub organization (or your personal account) that will
  host the public mirror and run Actions.
- Access to create GitHub OAuth Apps under that same org/user.

## 2. Versioning, tags, and changelog

Reviews starts public release tracking at `0.0.1-alpha.0`. Use semver
prerelease tags until the CLI contract, hosted service, and install assets are
stable enough for a non-alpha release.

Before cutting a release:

1. Update the version in `mix.exs`, `cli/Cargo.toml`, `cli/Cargo.lock`, and
   `assets/package.json`.
2. Add the user-facing changes to `CHANGELOG.md`.
3. Tag the CLI and server release separately:

   ```sh
   git tag cli-v0.0.1-alpha.0
   git tag server-v0.0.1-alpha.0
   git push origin cli-v0.0.1-alpha.0 server-v0.0.1-alpha.0
   ```

The `release-cli.yml` workflow publishes GitHub release assets named:

- `reviews-cli-<version>-linux-x64.tar.gz`
- `reviews-cli-<version>-linux-arm64.tar.gz`
- `reviews-cli-<version>-macos-x64.tar.gz`
- `reviews-cli-<version>-macos-arm64.tar.gz`

Each archive contains a `reviews` binary at its root plus `LICENSE`,
`README.md`, `install.sh`, and packaged `skills/`. The one-command installer
looks up the latest `cli-v*` release by default, or a specific tag when passed
`--version`.

---

## 3. Create the production GitHub OAuth App

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
   - **Homepage URL:** `https://reviews.figitaki.dev`
   - **Application description:** _(optional)_ "Code review tool for arbitrary
     diffs."
   - **Authorization callback URL:** `https://reviews.figitaki.dev/auth/github/callback`
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
curl -sI https://reviews.figitaki.dev/ | head -1   # expect: HTTP/2 200
```

### Smoke-test the flow

1. Open `https://reviews.figitaki.dev/auth/github` in an incognito window.
2. Authorize the app.
3. You should land back on the site, signed in. Navigate to `/settings` —
   you'll see a "Mint API token" control. Mint one to use with the CLI:

   ```sh
   reviews login
   # server_url: https://reviews.figitaki.dev
   # api_token:  <paste from /settings>
   ```

4. Test a push from any git checkout:

   ```sh
   cd ~/some-repo
   reviews push --title "test review"
   ```

   It should print a `https://reviews.figitaki.dev/r/<slug>` URL.

---

## 4. Other required Fly secrets

Beyond the GitHub OAuth pair, the app needs:

| Secret             | How to generate                                       | Notes                                                                 |
| ------------------ | ----------------------------------------------------- | --------------------------------------------------------------------- |
| `SECRET_KEY_BASE`  | `mix phx.gen.secret`                                  | 64-byte random hex. Phoenix raises at boot if unset.                  |
| `DATABASE_URL`     | Provisioned automatically by `fly postgres attach`    | `ecto://user:pass@host/db` format.                                    |
| `PHX_HOST`         | Already set in `fly.toml` (`reviews.figitaki.dev`)    | Change here, not as a secret, if you move to a custom domain.         |

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

## 5. Mirror the repo to GitHub

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

## 6. GitHub Actions: test + deploy

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

## 7. Manual deploy (escape hatch)

If CI is wedged or you need to push a hotfix from your laptop:

```sh
fly deploy -a reviews-dev
```

`fly deploy` reads `fly.toml` from the repo root, builds the Dockerfile, runs
the release command, and rolls the machines. It's the same thing CI does — CI
just runs it from a clean checkout with the API token.

---

## 8. Rollback

```sh
fly releases -a reviews-dev               # find the release you want
fly releases rollback <version> -a reviews-dev
```

This reverts the machine image but **does not** revert database migrations.
If the bad release included a migration that's destructive to roll back, you
need to ship a forward-fix migration instead — don't roll back blindly.

---

## 9. Custom domain

The app is served at `reviews.figitaki.dev`. DNS for `figitaki.dev` is managed
in Vercel (Vercel nameservers); the subdomain points at the Fly app via an
`A`/`AAAA` record pair:

| Type   | Name      | Value                      |
| ------ | --------- | -------------------------- |
| `A`    | `reviews` | `66.241.124.22`            |
| `AAAA` | `reviews` | `2a09:8280:1::114:8b7b:0`  |

Fly issues the TLS cert via Let's Encrypt (allowed by the `figitaki.dev` CAA
records). `ReviewsWeb.Plugs.CanonicalHost` 301-redirects the legacy
`reviews-dev.fly.dev` hostname to the custom domain.

To repoint at a different domain:

1. `fly certs add reviews.newdomain.com -a reviews-dev`
2. Add the DNS records Fly prints (an `A`/`AAAA` pair, or a `CNAME`).
3. Update `fly.toml`: change `PHX_HOST = 'reviews.newdomain.com'`.
4. Update the GitHub OAuth App's **Homepage URL** and
   **Authorization callback URL** to the new domain.
5. `fly deploy -a reviews-dev` to pick up the new `PHX_HOST`.

Until step 4, OAuth sign-ins from the new domain will fail with a callback
mismatch error.

---

## 10. Troubleshooting

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
`https://reviews.figitaki.dev/settings`, then `reviews login` again.

**Fly deploy succeeds but app boots-and-dies:**
Likely a missing required env (`SECRET_KEY_BASE`, `DATABASE_URL`). Check
`fly logs -a reviews-dev` — `runtime.exs` raises a clear message naming the
missing var.
