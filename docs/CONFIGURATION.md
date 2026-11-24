# Runtime configuration

Every setting the Reviews server reads, in one place. The server reads them
at boot, in `config/runtime.exs`, the release scripts in `rel/` and
`lib/reviews/release.ex`; nothing is read at compile time. Change a setting,
then restart every instance.

Settings come from environment variables, from a [config file](#config-file)
named by `REVIEWS_CONFIG`, or both. A set environment variable always wins
over the file.

Columns:

- **Required**: the server refuses to start in production without it.
- **Secret**: keep it out of logs, Git and plain config; deliver it as a
  secret (a Kubernetes Secret, `fly secrets`, `.env.local` in dev).
- **Helm value**: the [chart](../charts/reviews/README.md) value that sets
  it. `secret` means a key in the Secret named by `secrets.existingSecret`
  (every key there becomes an environment variable). `config.KEY` means the
  chart has no dedicated value; set that [config file](#config-file) key
  under `config:`. `env.NAME` means an environment variable under `env:`.

Unless a row says otherwise, a variable that is unset or empty counts as
unset, and boolean switches are on only for `true` or `1`.

## Core

| Variable | What it does | Default | Required | Secret | Helm value |
| --- | --- | --- | --- | --- | --- |
| `DATABASE_URL` | Postgres connection URL, `ecto://USER:PASS@HOST/DB` or `postgresql://…`. Production only; dev and test use the `POSTGRES_*` variables below. | none | yes | yes | `database.cluster.*` (CloudNativePG's `-app` Secret) or `database.existingSecret` / `database.existingSecretKey` |
| `SECRET_KEY_BASE` | Signs and encrypts cookies and sessions. Generate with `mix phx.gen.secret` or `openssl rand -hex 64`. Rotating it signs everyone out. | none | yes | yes | `secret` (generated when the chart creates the Secret) |
| `PHX_HOST` | Public hostname, without scheme or port. The app builds `https://<host>` URLs, redirects every other host there (`ReviewsWeb.Plugs.CanonicalHost`), accepts LiveView sockets from it, and allows it for hosted MCP. Your GitHub OAuth callback is `https://<host>/auth/github/callback`. | `example.com` (a placeholder that turns the redirect off) | in practice | no | `host` |
| `PORT` | HTTP port the server listens on. | `4000` | no | no | fixed at `4000` |
| `PHX_SERVER` | Starts the HTTP server. `bin/server` and the image set it; leave it alone unless you run `bin/reviews start` yourself. | `true` in the image | no | no | set by the image |
| `POOL_SIZE` | Database connections per instance. | `10` | no | no | `database.poolSize` |
| `ECTO_IPV6` | Connect to Postgres over IPv6. `rel/env.sh.eex` sets it on Fly. | off | no | no | `database.ipv6` |

### External URL, TLS and proxies

The app always generates `https://PHX_HOST` URLs on port 443 and redirects
plain HTTP to HTTPS (`force_ssl`, compile-time). It does not terminate TLS:
put a proxy or ingress in front that terminates TLS for `PHX_HOST` and sends
`X-Forwarded-Proto: https`. That proxy must pass WebSocket upgrades on
`/live` (LiveView). Any request whose `Host` is not `PHX_HOST` gets a 301 to
`https://PHX_HOST`, so use TCP health checks or send the public `Host`
header.

| Variable | What it does | Default | Required | Secret | Helm value |
| --- | --- | --- | --- | --- | --- |
| `WEBSOCKET_EXTRA_ORIGINS` | Comma-separated origins, besides `https://PHX_HOST`, that LiveView sockets accept, such as `https://old.example.com`. Use it while an old hostname redirects to a new one, so pages opened on the old host keep their socket. Set to empty for none. | none; on Fly, `https://reviews-dev.fly.dev` (the hosted site's old hostname) | no | no | `config.server.websocket_extra_origins` |
| `FLY_APP_NAME` | Set by Fly, not by you. When present, the server listens on IPv4 only and trusts `Fly-Client-IP` for rate limits ([ABUSE_PROTECTION.md](ABUSE_PROTECTION.md#client-ips-on-fly)), defaults `WEBSOCKET_EXTRA_ORIGINS` as above, and `rel/env.sh.eex` derives the node name and `DNS_CLUSTER_QUERY` from `FLY_APP_NAME`, `FLY_IMAGE_REF` and `FLY_PRIVATE_IP`. Elsewhere the server binds all IPv6 and IPv4 interfaces and rate-limits by socket peer. | unset | no | no | never set it |

Off Fly, rate limits key on the TCP peer, which behind a proxy is the
proxy. `X-Forwarded-For` is not trusted.

## GitHub sign-in

Anonymous viewing works without these. Signing in, commenting and API tokens
need a GitHub OAuth app whose callback URL is
`https://<PHX_HOST>/auth/github/callback` (`http://localhost:4000/…` in dev).

| Variable | What it does | Default | Required | Secret | Helm value |
| --- | --- | --- | --- | --- | --- |
| `GITHUB_CLIENT_ID` | GitHub OAuth app client ID. | none (sign-in shows a message instead) | for sign-in | no, but keep it with the secret | `secret` |
| `GITHUB_CLIENT_SECRET` | GitHub OAuth app client secret. | none | for sign-in | yes | `secret` |

## Erlang release and clustering

The release always starts Erlang distribution. Anyone who can reach the
distribution port and knows the cookie can run code on the node.

| Variable | What it does | Default | Required | Secret | Helm value |
| --- | --- | --- | --- | --- | --- |
| `RELEASE_COOKIE` | Erlang distribution cookie. The cookie built into the public image is known to everyone, so set a private one wherever the distribution port is reachable. | the image's built-in cookie | yes in the chart | yes | `secret` (generated when the chart creates the Secret) |
| `RELEASE_NODE` | Erlang node name. | `reviews@<hostname>`; on Fly, derived from the machine | no | no | `reviews@<pod IP>` with `clustering.enabled`, else `reviews@127.0.0.1` |
| `DNS_CLUSTER_QUERY` | DNS name whose records are the other instances; they join one cluster so live updates reach viewers on every instance. Unset means a single node. | unset; on Fly, `<FLY_APP_NAME>.internal` | for more than one instance | no | `clustering.enabled` (a headless Service) |
| `ERL_AFLAGS`, `ERL_ZFLAGS`, `ERL_EPMD_ADDRESS` | Standard Erlang VM flags. Fly sets `-proto_dist inet6_tcp`; the chart binds distribution to loopback without clustering. | per platform | no | no | set by the chart; IPv6 clusters add `env.ERL_AFLAGS` |
| `ERL_MAX_PORTS` | Size of the VM's port table. Set it where the container's open-file limit is huge, which otherwise costs about 1 GB at boot. | from the open-file limit | no | no | `65536` unless `env.ERL_MAX_PORTS` |
| `RELEASE_TMP` | Where the release writes runtime files. Point it at a writable directory when the root filesystem is read-only. | inside the release | no | no | `/tmp` |

## Optional features

| Variable | What it does | Default | Required | Secret | Helm value |
| --- | --- | --- | --- | --- | --- |
| `MCP_ENABLED` | Hosted MCP endpoint at `/mcp` ([MCP.md](MCP.md)). | off | no | no | `mcp.enabled` |
| `MCP_WRITES_ENABLED` | MCP write tools. Needs `MCP_ENABLED`. | off | no | no | `mcp.writesEnabled` |
| `DESIGN_CATALOG` | Design-system pages at `/design`. Production only; always on in dev. | off | no | no | `config.server.design_catalog` |
| `CODE_STORAGE_ADAPTER` | `code_storage` turns on storing each patchset's commits in [code.storage](https://code.storage). Any other value leaves it off. | off | no | no | `config.code_storage.enabled` |
| `CODE_STORAGE_ORG` | code.storage organization. | none | with the adapter | no | `config.code_storage.org` |
| `CODE_STORAGE_JWT_PRIVATE_KEY` | Unencrypted PKCS8 PEM, named-curve P-256 key that signs upload tokens. Real newlines or literal `\n` both work. | none | with the adapter | yes | `secret` |
| `CODE_STORAGE_POLICY` | `required` stops a push whose code upload fails; anything else is `optional`. | `optional` | no | no | `config.code_storage.policy` |
| `REVIEWS_ANALYTICS_TOKEN_SHA256` | SHA-256 (hex) of the aggregate-export credential ([AGGREGATE_EXPORT.md](AGGREGATE_EXPORT.md)). The export is off unless this and the expiry are both valid. | off | no | yes | `secret` |
| `REVIEWS_ANALYTICS_TOKEN_EXPIRES_AT` | UTC ISO-8601 expiry of that credential, at most 90 days ahead. | off | no | yes | `secret` |

More on code storage, and what it does and does not enforce, is in the
[README](../README.md#code-storage-optional).

### Privacy Policy and Terms of Service

All unset means no `/privacy` or `/terms` page and no links to them. For each
document, set its URL or fill in its built-in template; a partly filled
template stops the server from starting. None are secrets or required.
[LEGAL_PAGES.md](LEGAL_PAGES.md) explains the choices and gives examples.

| Variable | What it does | Helm value |
| --- | --- | --- |
| `LEGAL_PRIVACY_URL` | Your own Privacy Policy; `/privacy` redirects there. | `legal.privacyUrl` |
| `LEGAL_TERMS_URL` | Your own Terms of Service; `/terms` redirects there. | `legal.termsUrl` |
| `LEGAL_OPERATOR_NAME` | Both templates: who runs the site. | `legal.operatorName` |
| `LEGAL_CONTACT_EMAIL` | Both templates: contact address. | `legal.contactEmail` |
| `LEGAL_UPDATED` | Both templates: "Last updated" date. | `legal.updated` |
| `LEGAL_HOSTING_REGION` | Privacy template: where data is hosted. | `legal.hostingRegion` |
| `LEGAL_LOG_RETENTION` | Privacy template: request log retention. | `legal.logRetention` |
| `LEGAL_BACKUP_RETENTION` | Privacy template: backup retention. | `legal.backupRetention` |
| `LEGAL_GOVERNING_LAW` | Terms template: governing law. | `legal.governingLaw` |
| `LEGAL_VENUE` | Terms template: venue for disputes. | `legal.venue` |
| `LEGAL_LIABILITY_CAP` | Terms template: liability cap. | `legal.liabilityCap` |

## Preview deployments

Only for per-PR preview apps ([PREVIEW_ENVS.md](PREVIEW_ENVS.md)). A normal
installation sets none of these.

| Variable | What it does | Default | Required | Secret | Helm value |
| --- | --- | --- | --- | --- | --- |
| `AUTH_RELAY_SECRET` | Shared key for the GitHub sign-in relay. On the relay (a site with its own GitHub OAuth app) it turns the relay on; on a preview, together with `AUTH_RELAY_URL`, it signs in through the relay. | off | no | yes | `secret` |
| `AUTH_RELAY_URL` | On a preview: the relay's origin, such as `https://reviews.example.com`. | unset (this site is not a preview) | no | no | `config.auth_relay.url` |
| `AUTH_RELAY_PREVIEW_HOST` | Preview hostname with `*` where the PR number goes. The relay sends users only to hosts that match it, with digits for `*`, and previews accept relay codes only on such a host. Set the same value on the relay and its previews. Lowercase hostname characters and exactly one `*`, or the server refuses to start. | `reviews-pr-*.fly.dev` | no | no | `config.auth_relay.preview_host` |
| `PREVIEW_DB_NAME` | `bin/migrate` creates this database if it is missing. Must be `reviews_pr_<digits>` and match `DATABASE_URL`. | unset (no create) | no | no | not used |
| `PREVIEW_API_TOKEN` | `bin/migrate` seeds a "preview" user with this API token, so the CLI can push without GitHub. Never set it on a real installation. | unset (no user) | no | yes | not used |

Pick a preview host pattern under a domain only you can create names in: any
host that matches it can receive sign-in codes.

## Development and tests only

Read by `config/dev.exs` and `config/test.exs`; ignored in production.

| Variable | What it does | Default |
| --- | --- | --- |
| `POSTGRES_HOST`, `POSTGRES_PORT` | Connect to Postgres over TCP. Unset means the unix socket. | socket |
| `POSTGRES_SOCKET_DIR` | Unix socket directory. | `/tmp` |
| `POSTGRES_USER`, `POSTGRES_PASSWORD` | Database credentials. | `reviews`, empty |
| `MIX_TEST_PARTITION` | Suffix for the test database, so parallel runs do not share it. | none |
| `OAUTH_ISSUER` | Public HTTPS URL that reaches the dev server (such as a tunnel), for OAuth connectors. | none |
| `OAUTH_ALLOW_PRIVATE_HOSTS` | Comma-separated OAuth client hosts allowed to resolve to private addresses. | none |
| `PORT` | Dev server port. | `4000` |

`.env.example` lists the ones a new checkout usually needs; copy it to
`.env.local`, which `./bin/server` loads.

## Config file

Set `REVIEWS_CONFIG` to the path of a YAML file to keep settings in one file
instead of many environment variables.
[`config/reviews.example.yaml`](../config/reviews.example.yaml) is an
annotated example with every key. The Helm chart writes this file from its
values into a ConfigMap, mounts it at `/etc/reviews/reviews.yaml` and sets
`REVIEWS_CONFIG`.

- **Environment wins.** Each key stands for one environment variable (below).
  When that variable is set, even to an empty string, the file's key is
  ignored. A deployment with no file, such as the hosted site on Fly, works
  exactly as before. The image sets `PORT=4000`, so `server.port` only
  applies where `PORT` is unset.
- **Secrets are files, never inline.** A secret's key ends in `_file` and
  names a file holding the value, such as a Kubernetes Secret mounted as a
  volume or a Docker secret under `/run/secrets`. A trailing newline is
  dropped. The file is read only when the environment variable is unset, so
  a secret can also come from the environment. Writing a secret inline, such
  as `github.client_secret: …`, is an error that names the `_file` key to use.
  There is no `${VAR}` substitution.
- **Checked at boot.** An unknown key, a wrong type, an unreadable or empty
  secret file, or invalid YAML stops the server. The error names every bad
  key by its path, such as `server.port: must be a port number from 1 to
  65535, got 70000`, and never prints a secret.
- **Types.** Booleans are `true` or `false`; numbers are whole numbers above
  0. A key that is missing or `null` takes its default.

| File key | Environment variable | Type |
| --- | --- | --- |
| `server.host` | `PHX_HOST` | string |
| `server.port` | `PORT` | port |
| `server.secret_key_base_file` | `SECRET_KEY_BASE` | secret file |
| `server.websocket_extra_origins` | `WEBSOCKET_EXTRA_ORIGINS` | list of origins, `[]` for none |
| `server.design_catalog` | `DESIGN_CATALOG` | boolean |
| `database.url_file` | `DATABASE_URL` | secret file |
| `database.pool_size` | `POOL_SIZE` | number |
| `database.ipv6` | `ECTO_IPV6` | boolean |
| `cluster.dns_query` | `DNS_CLUSTER_QUERY` | string |
| `github.client_id` | `GITHUB_CLIENT_ID` | string |
| `github.client_secret_file` | `GITHUB_CLIENT_SECRET` | secret file |
| `mcp.enabled`, `mcp.writes_enabled` | `MCP_ENABLED`, `MCP_WRITES_ENABLED` | boolean |
| `code_storage.enabled` | `CODE_STORAGE_ADAPTER` (`true` means `code_storage`) | boolean |
| `code_storage.org` | `CODE_STORAGE_ORG` | string |
| `code_storage.jwt_private_key_file` | `CODE_STORAGE_JWT_PRIVATE_KEY` | secret file |
| `code_storage.policy` | `CODE_STORAGE_POLICY` | `optional` or `required` |
| `legal.privacy_url`, `legal.terms_url`, `legal.operator_name`, `legal.contact_email`, `legal.updated`, `legal.hosting_region`, `legal.log_retention`, `legal.backup_retention`, `legal.governing_law`, `legal.venue`, `legal.liability_cap` | the matching `LEGAL_*` variable | string |
| `analytics.token_sha256_file` | `REVIEWS_ANALYTICS_TOKEN_SHA256` | secret file |
| `analytics.token_expires_at` | `REVIEWS_ANALYTICS_TOKEN_EXPIRES_AT` | string |
| `auth_relay.secret_file` | `AUTH_RELAY_SECRET` | secret file |
| `auth_relay.url`, `auth_relay.preview_host` | `AUTH_RELAY_URL`, `AUTH_RELAY_PREVIEW_HOST` | string |
| `limits.rate.requests`, `.writes`, `.uploads`, `.sockets`, `.owners` | none; per-client requests per minute ([ABUSE_PROTECTION.md](ABUSE_PROTECTION.md)), defaults 300, 60, 20, 60, 60 | number |
| `limits.body_bytes.upload`, `.mcp`, `.other` | none; largest request body in bytes, defaults 50000000, 4000000, 64000 | number |

Some settings are environment-only, because something reads them before the
file or outside the server: `REVIEWS_CONFIG` itself, `PHX_SERVER`,
`FLY_APP_NAME`, the Erlang release variables (`RELEASE_*`, `ERL_*`, read by
the release scripts before `runtime.exs`), the preview seeding variables
`PREVIEW_DB_NAME` and `PREVIEW_API_TOKEN`, and the development and test
variables.

## Database and migrations

Postgres 14 or newer; CI runs the tests on Postgres 16. Migrations run with
`Reviews.Release.migrate()`. `bin/migrate`, which Fly runs before each
deploy, also creates the preview database when `PREVIEW_DB_NAME` is set,
seeds the bundled demo review at `/r/demo-review`, and seeds the preview user
when `PREVIEW_API_TOKEN` is set. The Helm chart runs migrations only, and
seeds the demo review only with `demo.enabled`. Rolling back the image does
not revert migrations; see [RELEASE.md](RELEASE.md#8-rollback).
