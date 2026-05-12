# Phoenix base-path support (feeler ticket)

**Status:** Open · feeler / scoping · not yet committed work
**Created:** 2026-05-11
**Owner:** unassigned

## Problem

`reviews` only works when served at the URL root (`/`). The homelab GitOps
scaffold (`~/src/homelab/cluster/tinycube/apps/reviews/`) currently sidesteps
this by routing on a dedicated tailnet host (`reviews.tail154620.ts.net`)
with Phoenix at `/`.

We can't host `reviews` under a path prefix (e.g. `tinycube-server.tail154620.ts.net/reviews`)
without app changes. An earlier attempt used Traefik `stripPrefix` to chop
`/reviews` off the request before forwarding to Phoenix at `/`. Phoenix then
emits root-relative URLs everywhere (LiveView socket, OAuth redirect, static
assets, links, redirects). The browser resolves those against the host root,
bypassing the prefix, and the app breaks.

For homelab co-tenancy on a single tailnet host — and for any future
self-hosted multi-app deployment behind one reverse proxy — Phoenix needs to
know it's mounted at a non-root path.

## Why it matters

- **Operational:** lets us put `reviews` alongside `mdpub`, `mdpub-standups`,
  `grafana`, etc. on `tinycube-server.tail154620.ts.net` without minting a
  new tailnet hostname + OAuth app per service.
- **Self-hosting story:** today the docs effectively require a dedicated
  hostname. People deploying reviews behind their own gateway will hit the
  same wall.
- **Optionality:** not a blocker right now (the host-based homelab ingress
  works), but the workaround spreads cost — every new internal app gets its
  own tailnet hostname unless we fix this.

Not urgent. This is "feeler" — confirm scope before scheduling.

## Surface area (what has to change)

A non-exhaustive list of every place `/` is implied:

1. **Endpoint URL config** — `config/config.exs` and `config/runtime.exs`
   currently set `url: [host: ...]`. Phoenix's `Endpoint` supports
   `url: [path: "/reviews"]`; that needs to be threaded through.
2. **`script_name`** — required so the router strips the prefix from
   incoming paths the same way the proxy does. (If we keep proxy
   `stripPrefix` we don't need `script_name` because the prefix never
   reaches the app; if we drop `stripPrefix` we do. Decide which side owns
   the trim.)
3. **Static assets** — `Plug.Static` in `lib/reviews_web/endpoint.ex:23-28`
   mounts at `at: "/"`. With a prefix-aware app it would mount at the
   prefix, OR `script_name` covers it — needs verification.
4. **LiveView socket** — `socket "/live", Phoenix.LiveView.Socket, …` in
   `endpoint.ex:14-16` and the JS client in `assets/js/app.js:30`
   (`new LiveSocket("/live", …)`). Both endpoints assume `/live` is at the
   host root. With a prefix, the JS needs `/<prefix>/live` (or a
   server-rendered socket path).
5. **Router scopes** — `lib/reviews_web/router.ex:22,31,39,58,64` use
   bare `scope "/"`. With `script_name` they stay correct; without it
   they each gain the prefix. The Ueberauth scope at `/auth` and the API
   scope at `/api/v1` matter for external callers (CLI, OAuth).
6. **GitHub OAuth callback URL** — registered in the GitHub OAuth App as
   an absolute URL. Today: `https://<host>/auth/github/callback`. With a
   prefix: `https://<host>/reviews/auth/github/callback`. Has to match
   what Ueberauth generates; document at deploy time.
7. **Asset URLs from JS / React island** — anywhere our own JS builds
   URLs to API endpoints (the CLI hits `POST /api/v1/reviews`; any
   in-browser fetches use root-relative paths). Audit:
   - `assets/js/app.js`
   - `assets/js/hooks/diff_renderer.js`
   - any other React-island fetches
8. **CLI base URL** — `cli/` already defaults to `https://reviews-dev.fly.dev`
   (commit `5624544`). If a deployment runs on a base path, the CLI's
   URL config needs to accept paths (e.g. `https://host/reviews`).
   Most likely already works since it's just a base URL, but verify
   `cli/` URL construction doesn't strip paths.
9. **Tests** — `mix test` exercises routing through `Phoenix.ConnTest`,
   which respects `script_name`. Probably mostly free, but anywhere a
   test hard-codes `"/r/<slug>"` etc. needs review.
10. **Telemetry / logging** — if any structured log fields capture path,
    confirm we're capturing the application path, not the proxied path
    (or both, deliberately).

## Implementation options

### Option A — proxy strips prefix, Phoenix unaware (rejected)
What the homelab scaffold attempted. Already shown not to work because
Phoenix generates root-relative URLs the browser then resolves against
the host root. **Listed for completeness only — do not pursue.**

### Option B — `script_name` everywhere, proxy still strips
Set `config :reviews, ReviewsWeb.Endpoint, url: [path: "/reviews"]` and
mount the router under `script_name: ["reviews"]` (via `forward` or by
configuring the endpoint). Proxy continues to `stripPrefix`, so the
app's internal URLs still start at `/`, but `Phoenix.Router.Helpers`
prepend the prefix when generating URLs for the browser. JS socket URLs
must also be prefixed (`"/reviews/live"` in `app.js`, possibly via a
data attribute on `<body>` so the prefix isn't hardcoded).

- **Pros:** Phoenix internals stay simple; matches the standard Phoenix
  recommendation for path-prefixed deployments.
- **Cons:** Two places own the prefix knowledge (proxy + app). Easy to
  desync. Have to pass the prefix into JS at runtime.

### Option C — Phoenix owns the prefix, proxy passes-through
Don't `stripPrefix` at the proxy. Mount the entire router under a
scoped path (`scope "/reviews", ReviewsWeb do … end`) and set
`Plug.Static` at `at: "/reviews"`. LiveView socket at `/reviews/live`.

- **Pros:** Single source of truth (the app); the proxy is dumb.
- **Cons:** Invasive — touches every scope in the router and the JS
  socket URL. Harder to keep dev vs. prod symmetric (dev would need the
  same prefix or a conditional).

### Option D — runtime-configurable base path
Same as B or C, but the prefix is a runtime env var (`BASE_PATH`)
rather than a compile-time constant. Endpoint, socket, and router
read it. JS reads it from a data attribute Phoenix renders into the
layout.

- **Pros:** One image, many deployments at different paths. Best for
  the self-hosting story.
- **Cons:** Most code to write; runtime config in Phoenix routing is
  fiddly (Plug pipelines compile-time, scopes can be parameterized but
  it's not idiomatic).

**Recommended starting point:** Option B with the prefix hard-coded
behind one config knob in `config/runtime.exs`. Ships path-prefix
support without committing to a fully runtime-configurable design.
Promote to D later if multi-tenant self-hosting becomes a real ask.

## Risks

- **OAuth state mismatch.** GitHub callback URL has to match exactly.
  Easy to misconfigure on first deploy.
- **LiveView reconnect loops** if the JS socket URL doesn't match the
  endpoint socket mount. Fail-fast: if `LiveSocket` 404s, the whole UI
  is dead.
- **Static asset 404s** are silent in production unless someone is
  watching the access log. Need to validate `priv/static` is served
  under the prefix.
- **Dev vs. prod divergence.** If we only apply the prefix in prod
  config, local dev keeps working at `/` and the path-prefix bugs only
  show up in deployed environments. Mitigate with a `mix test` env
  that exercises the prefix, or a `bin/server` flag.
- **CLI breakage.** If `cli/` does URL concat naively, base paths could
  double-prefix or get dropped. Needs a test.

## Acceptance criteria

A reasonable v1 implementation of this should be able to:

1. Run locally with `BASE_PATH=/reviews ./bin/server` and have
   `http://localhost:4000/reviews/` serve the index, with the diff
   renderer, LiveView, and OAuth flow all working end-to-end.
2. Pass `mix test` with the prefix applied (or with a parallel test
   env that applies the prefix).
3. Deploy to the homelab cluster under `tinycube-server.tail154620.ts.net/reviews`
   with Traefik `stripPrefix` re-enabled, GitHub OAuth pointing at
   `/reviews/auth/github/callback`, and all of: page load, LiveView
   updates, OAuth login, `reviews push` from the CLI, asset 200s.
4. Document the toggle in `docs/` (or wherever deploy docs live) so
   someone self-hosting can flip it without reading the source.
5. Leave the root-mounted case (today's default) working unchanged
   when the prefix is unset.

## Out of scope (for this ticket)

- Multi-tenancy at the data layer.
- Per-tenant config or rate limiting.
- A `BASE_URL` env that changes scheme/host (different concern).
- Removing the dedicated-host homelab ingress. The host-based ingress
  remains the supported / recommended path even after this lands; this
  ticket just makes path routing an option.

## Pointers

- Homelab scaffold using host-based routing (the workaround):
  `~/src/homelab/cluster/tinycube/apps/reviews/ingress-host.yaml`
- Earlier path-based ingress (reverted in commit `916b204`,
  `2026-05-11`):
  `cluster/tinycube/apps/reviews/ingress-path*.yaml`,
  `middleware-strip-prefix.yaml`.
- Endpoint: `lib/reviews_web/endpoint.ex`
- Router: `lib/reviews_web/router.ex`
- JS socket: `assets/js/app.js`
- Phoenix docs on path prefixes (script_name):
  `https://hexdocs.pm/phoenix/Phoenix.Endpoint.html` (search `url`/`path`).
