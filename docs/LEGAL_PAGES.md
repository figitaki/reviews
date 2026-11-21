# Privacy Policy and Terms of Service

Each deployment decides whether it has a Privacy Policy and Terms of Service,
and where they live. Reviews does not ship an operator: with nothing
configured there is no `/privacy` or `/terms` page (both return 404), the
footer has no Privacy or Terms link, and sign-in and approval screens show no
"you agree" line.

For each document, choose one:

- **Your own policy.** Set its URL. `/privacy` or `/terms` redirects there,
  and every link points at it.
- **The built-in template.** Set every field the template needs. Reviews
  renders it at `/privacy` or `/terms`, filled in from these settings.
- **None.** Leave its settings unset.

The two documents are independent. With only terms, the sign-in line reads
"By signing in, you agree to the Terms of Service."; with only a privacy
policy, "By signing in, you acknowledge the Privacy Policy."

The built-in templates are a starting point, not legal advice. Have them
reviewed for your organization and jurisdiction before you turn them on.

## Settings

All are plain environment variables, read in `config/runtime.exs` into
`config :reviews, :legal` (`Reviews.Legal`). In the Helm chart they are the
`legal.*` values.

| Environment variable | Helm value | Used by | Example |
| --- | --- | --- | --- |
| `LEGAL_PRIVACY_URL` | `legal.privacyUrl` | Your own Privacy Policy | `https://example.com/privacy` |
| `LEGAL_TERMS_URL` | `legal.termsUrl` | Your own Terms of Service | `https://example.com/terms` |
| `LEGAL_OPERATOR_NAME` | `legal.operatorName` | Both templates | `Example Ltd.` |
| `LEGAL_CONTACT_EMAIL` | `legal.contactEmail` | Both templates | `privacy@example.com` |
| `LEGAL_UPDATED` | `legal.updated` | Both templates ("Last updated") | `2026-11-21` |
| `LEGAL_HOSTING_REGION` | `legal.hostingRegion` | Privacy template | `the European Union` |
| `LEGAL_LOG_RETENTION` | `legal.logRetention` | Privacy template | `30 days` |
| `LEGAL_BACKUP_RETENTION` | `legal.backupRetention` | Privacy template | `7 days` |
| `LEGAL_GOVERNING_LAW` | `legal.governingLaw` | Terms template | `England and Wales` |
| `LEGAL_VENUE` | `legal.venue` | Terms template | `London` |
| `LEGAL_LIABILITY_CAP` | `legal.liabilityCap` | Terms template | `US$100` |

Values are inserted as written, so phrase them to read in a sentence: "hosted
in **the European Union**", "governed by the laws of **England and Wales**",
"Request logs: **30 days**." Blank values count as unset.

A URL wins over the template for its document. A template whose own fields
(region and retention for privacy; law, venue and cap for terms) are partly
set is an error: the server refuses to start and names the missing
variables, so a half-filled policy never ships. Setting only the shared
fields (operator, contact, date) turns neither template on.

## What the privacy template describes

The template describes what the server stores, logs and shares: GitHub
sign-in data, reviews and comments, identities, API tokens, OAuth and agent
grants, the session cookie, request logs and rate limiting. Parts that
depend on the deployment appear only when they are on:

- code snapshots and code.storage, when `CODE_STORAGE_ADAPTER` is set;
- MCP connectors and their names, when `MCP_ENABLED` is set;
- the aggregate usage export, when its credential is configured
  ([AGGREGATE_EXPORT.md](AGGREGATE_EXPORT.md));
- preview deployments, when this server is the sign-in relay
  ([PREVIEW_ENVS.md](PREVIEW_ENVS.md)).

The site's hostname comes from `PHX_HOST`. Anything else your deployment adds,
such as a CDN, log shipping or error tracking, is not covered: use your own
policy URL instead.

## Examples

Your own policies:

```sh
LEGAL_PRIVACY_URL=https://example.com/privacy
LEGAL_TERMS_URL=https://example.com/terms
```

Both built-in templates, in Helm values:

```yaml
legal:
  operatorName: Example Ltd.
  contactEmail: privacy@example.com
  updated: "2026-11-21"
  hostingRegion: the European Union
  logRetention: 30 days
  backupRetention: 7 days
  governingLaw: England and Wales
  venue: London
  liabilityCap: US$100
```
