# Reviews Helm chart

This chart runs the Reviews server on Kubernetes. Its Postgres database is a
[CloudNativePG](https://cloudnative-pg.io/) `Cluster` that the chart creates,
or any Postgres you already run.

The chart is published to `oci://ghcr.io/figitaki/charts/reviews`. It runs the
public image `ghcr.io/figitaki/reviews-server`, built for linux/amd64 and
linux/arm64.

What you get:

- A Deployment of the server. An init container runs the database
  migrations before each pod starts.
- A CloudNativePG `Cluster` named `<release>-db`, kept when the release is
  uninstalled. You can turn it off and point at another database instead.
- Object names built from the release name. A name longer than 47 characters
  is shortened to its first 38 plus 8 hex of its hash, so the Cluster stays
  within CloudNativePG's 50-character limit and long release names that share
  a prefix still get their own objects.
- A Service, and optionally an Ingress for any controller.
- Optionally, a headless Service for Erlang clustering across replicas.

## Prerequisites

- Kubernetes. The chart is tested on 1.37 with CloudNativePG 1.30.
- The CloudNativePG operator, if the chart creates the database. Install it
  once per cluster, for example:

  ```sh
  kubectl apply --server-side -f \
    https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/cnpg-1.30.1.yaml
  ```

- An ingress controller and TLS for the public host. The app redirects plain
  HTTP to `https://<host>`, so something in front of it must terminate TLS
  and send `X-Forwarded-Proto: https`. Traefik and ingress-nginx both do.
- Helm 3.8 or newer, for OCI charts.

## Install

1. Create the namespace and a Secret with the app's secrets. Every key in
   the Secret becomes an environment variable:

   ```sh
   kubectl create namespace reviews
   kubectl -n reviews create secret generic reviews-env \
     --from-literal=SECRET_KEY_BASE="$(openssl rand -hex 64)" \
     --from-literal=RELEASE_COOKIE="$(openssl rand -hex 32)" \
     --from-literal=GITHUB_CLIENT_ID=<client-id> \
     --from-literal=GITHUB_CLIENT_SECRET=<client-secret>
   ```

   The GitHub OAuth app's callback URL is
   `https://<host>/auth/github/callback`. See
   [docs/RELEASE.md](../../docs/RELEASE.md) for how to create one. In GitOps
   setups, create this Secret with SOPS, External Secrets or Sealed Secrets
   rather than by hand.

2. Write a values file:

   ```yaml
   host: reviews.example.com
   secrets:
     existingSecret: reviews-env
   ingress:
     enabled: true
     className: traefik
     annotations:
       cert-manager.io/cluster-issuer: letsencrypt
     tlsSecretName: reviews-tls
   ```

3. Install:

   ```sh
   helm install reviews oci://ghcr.io/figitaki/charts/reviews \
     --version 0.0.3 --namespace reviews -f values.yaml --wait --timeout 10m
   ```

The first install takes a minute or two. CloudNativePG starts Postgres and
creates the `reviews-db-app` Secret. App pods wait for that Secret, then run
migrations, then start. Check progress with:

```sh
kubectl -n reviews get cluster,pods
kubectl -n reviews logs deploy/reviews -c migrate
```

Without `secrets.existingSecret`, the chart creates `<release>-secrets` with a
random `SECRET_KEY_BASE` and `RELEASE_COOKIE`, and keeps them on upgrade.
That is enough to try the chart, but GitHub sign-in needs its own keys.

`RELEASE_COOKIE` is required in every install, clustered or not. The server
always starts Erlang distribution, and the cookie built into the public image
is known to anyone, so a pod whose Secret lacks the key does not start.

## Values

| Key | Default | What it does |
| --- | --- | --- |
| `host` | `reviews.example.com` | Public hostname. Sets `PHX_HOST` and the Ingress host. Other hosts redirect here. |
| `image.repository` | `ghcr.io/figitaki/reviews-server` | Server image. |
| `image.tag` | `server-v<appVersion>` | Image tag. Empty runs the server released with this chart version. Set a commit build (`sha-<12 hex>`) to run something else. |
| `image.digest` | `""` | Pull by digest (`sha256:...`) instead of by tag. |
| `replicaCount` | `1` | App pods. Turn on `clustering` when it is more than 1. |
| `secrets.existingSecret` | `""` | Secret loaded as environment variables. Must hold `SECRET_KEY_BASE` and `RELEASE_COOKIE`; add `GITHUB_CLIENT_ID` and `GITHUB_CLIENT_SECRET` for sign-in, and any other secret setting such as `CODE_STORAGE_JWT_PRIVATE_KEY`. Empty means a generated Secret. |
| `database.cluster.enabled` | `true` | Create a CloudNativePG `Cluster` named `<release>-db`. |
| `database.cluster.instances` | `1` | Postgres instances. 2 or more gives a standby to fail over to. |
| `database.cluster.imageName` | `""` | Postgres image. Empty means the operator's default. |
| `database.cluster.storage.size` | `5Gi` | Volume size per instance. |
| `database.cluster.storage.storageClass` | `""` | StorageClass. Empty means the cluster default. |
| `database.cluster.resources` | `{}` | Postgres pod resources. |
| `database.cluster.parameters` | `{}` | `postgresql.parameters`, such as `max_connections`. |
| `database.cluster.spec` | `{}` | Extra `Cluster` spec fields merged in, such as `backup`, `affinity` or `monitoring`. |
| `database.cluster.keep` | `true` | Keep the `Cluster` and its volumes when the release is uninstalled. |
| `database.existingSecret` | `""` | With `cluster.enabled: false`, the Secret holding the database URL. |
| `database.existingSecretKey` | `uri` | Key in that Secret. |
| `database.poolSize` | `10` | Connections per app pod (`POOL_SIZE`). |
| `database.ipv6` | `false` | Connect to Postgres over IPv6 (`ECTO_IPV6`). |
| `migrations.enabled` | `true` | Run Ecto migrations in an init container. |
| `migrations.resources` | `{}` | Init container resources. |
| `demo.enabled` | `false` | Seed the demo review at `/r/demo-review`, which the home page links to. |
| `clustering.enabled` | `false` | Join pods into one Erlang cluster through a headless Service. |
| `mcp.enabled` | `false` | Hosted MCP endpoint at `/mcp` ([docs/MCP.md](../../docs/MCP.md)). |
| `mcp.writesEnabled` | `false` | MCP write tools. |
| `legal.privacyUrl`, `legal.termsUrl` | `""` | Link your own Privacy Policy or Terms of Service (`LEGAL_PRIVACY_URL`, `LEGAL_TERMS_URL`). |
| `legal.operatorName`, `.contactEmail`, `.updated`, `.hostingRegion`, `.logRetention`, `.backupRetention`, `.governingLaw`, `.venue`, `.liabilityCap` | `""` | Fill in the built-in templates instead (`LEGAL_*`). All empty means no legal pages or links. See [docs/LEGAL_PAGES.md](../../docs/LEGAL_PAGES.md). |
| `env` | `{}` | Extra plain environment variables, such as `CODE_STORAGE_ADAPTER` or `DESIGN_CATALOG`. |
| `service.type`, `service.port` | `ClusterIP`, `80` | App Service. |
| `ingress.enabled` | `false` | Create an Ingress for `host`. |
| `ingress.className` | `""` | IngressClass, such as `traefik` or `nginx`. |
| `ingress.annotations` | `{}` | Ingress annotations, such as `cert-manager.io/cluster-issuer`. |
| `ingress.tlsSecretName` | `""` | TLS Secret for `host`. cert-manager creates it when the issuer annotation is set. |
| `serviceAccount.create`, `.name`, `.annotations` | `true`, `""`, `{}` | Pod ServiceAccount. The pod does not mount its token. |
| `resources` | 100m CPU and 512Mi requested, 1Gi memory limit | App container resources. |
| `podAnnotations`, `podLabels`, `nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints` | empty | Pod scheduling and metadata. |

[`ci/production-values.yaml`](ci/production-values.yaml) is a fuller example:
two clustered replicas, two Postgres instances, Traefik and cert-manager.

### Database

With `database.cluster.enabled: true`, `DATABASE_URL` comes from the `uri` key
of the `<release>-db-app` Secret that CloudNativePG writes. The app connects to
the `-rw` Service, so it follows failover to a new primary.

To use a database the chart does not manage, turn the cluster off and name a
Secret in the release namespace that holds an `ecto://` or `postgresql://`
URL. Another CloudNativePG cluster's `-app` Secret works as is:

```yaml
database:
  cluster:
    enabled: false
  existingSecret: shared-pg-app
  existingSecretKey: uri
```

The Cluster carries `helm.sh/resource-policy: keep`, so `helm uninstall` and
turning `cluster.enabled` off leave the database running. Installing again
with the same release name and namespace adopts it. To drop the data, delete
it yourself: `kubectl -n reviews delete cluster reviews-db`.

Backups are not on by default. Add them through `database.cluster.spec`; see
the CloudNativePG backup docs.

### Migrations

Every app pod runs `Reviews.Release.migrate()` in an init container. Ecto
locks `schema_migrations`, so pods that start together run migrations one at
a time. If a migration fails, the new pod never starts and the old pods keep
serving. A migration that succeeds changes the shared database before the
new pods are ready, so the old pods keep serving only if they work with the
new schema. Rolling back the image does not revert migrations; after an
incompatible migration, ship a forward fix instead, as
[docs/RELEASE.md](../../docs/RELEASE.md#8-rollback) describes.

The init container runs migrations only. Fly's `release_command`
(`/app/bin/migrate`) also seeds the demo review; here that is opt-in with
`demo.enabled: true`. The seed then runs in a second init container under a
Postgres advisory lock, so pods seed one at a time. If it fails, or waits more
than about a minute for the lock, it logs the failure and the pod starts
anyway. Without the demo, the home page's "Open demo review" link returns 404.

### Probes

A pod is ready only while it can query Postgres: the readiness probe runs
`SELECT 1` through the app's own connection pool with `bin/reviews rpc`. The
liveness and startup probes only check that port 4000 accepts connections, so
a database outage takes pods out of the Service without restarting them.

### Clustering

With `clustering.enabled: true`, the chart adds a headless Service and sets
`DNS_CLUSTER_QUERY` to it. Each pod names itself `reviews@<pod IP>` and
connects to the others, so live updates reach viewers on any pod. The pods
share the `RELEASE_COOKIE` from the Secret. Pods must reach each other on TCP
4369 (epmd) and the Erlang distribution port, which is random, so allow
traffic between the app pods in any NetworkPolicy, and block it from
everything else: anyone who can reach those ports with the cookie can run
code on the node. On an IPv6-only cluster, also set
`env.ERL_AFLAGS: "-proto_dist inet6_tcp"` and `database.ipv6: true`.

Without clustering, epmd and the distribution port listen on the pod's
loopback interface only (`RELEASE_NODE=reviews@127.0.0.1`), so
`kubectl exec ... -- /app/bin/reviews rpc ...` still works and nothing outside
the pod can connect.

### Ingress and TLS

The Ingress only takes a class, annotations and a TLS Secret name, so it works
with any controller. With Traefik and cert-manager's ACME HTTP-01 issuer:

```yaml
ingress:
  enabled: true
  className: traefik
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
  tlsSecretName: reviews-tls
```

cert-manager sees the annotation, solves the challenge on port 80 and writes
`reviews-tls`. LiveView uses WebSockets on `/live`; Traefik and ingress-nginx
pass them through without extra settings. The app only accepts WebSocket
connections whose `Origin` is `https://<host>` or `https://reviews-dev.fly.dev`,
the hosted site's legacy hostname, which `config/runtime.exs` also allows.

### Versions and image tags

The chart is versioned with the rest of Reviews: chart `0.0.3` is part of
release `0.0.3`, and by default it runs the image `server-v0.0.3`, the server
it was released and tested with. To run a release, install the chart
version of the same number and leave `image.tag` empty.

Every push to `main` also publishes `main` and
`sha-<first 12 hex of the commit>`. `main` moves, so do not deploy it. A
`sha-` tag runs a build from `main` with the chart you have installed; a
build newer than the chart may need chart changes that come only with the
next release.

## Continuous deployment with Flux

The pattern below keeps every deploy as a commit in your Git repository:

- Flux pulls the chart from GHCR as an OCI Helm repository.
- The `HelmRelease` pins an exact chart version.
- Values live in Git as plain YAML. A separate pins file holds only the image
  tag, so a deploy is a one-line change, made by hand or by a workflow that
  opens a pull request.
- Failed upgrades roll back.

The examples are tested with Flux 2.10. They assume a directory such as
`apps/reviews/` that a Flux `Kustomization` already applies. Create the
`reviews-env` Secret from [Install](#install) in the `reviews` namespace too.

```text
apps/reviews/
├── kustomization.yaml
├── kustomizeconfig.yaml
├── namespace.yaml
├── reconciler.yaml
├── helmrepository.yaml
├── helmrelease.yaml
├── values.yaml
└── pins.yaml
```

### Source

```yaml
# helmrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: reviews
  namespace: flux-system
spec:
  type: oci
  interval: 1h
  url: oci://ghcr.io/figitaki/charts
```

The chart is public, so no credentials are needed.

### Reconciler account

The `HelmRelease` below runs as its own service account, limited to the
`reviews` namespace. Kubernetes' `admin` role does not cover CloudNativePG
resources, so the account also gets a Role for `Cluster`s. If your
helm-controller runs with cluster-admin and you do not use impersonation,
skip this file and drop `serviceAccountName`.

```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: reviews
```

```yaml
# reconciler.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: reviews-reconciler
  namespace: flux-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: reviews-reconciler-admin
  namespace: reviews
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
  - kind: ServiceAccount
    name: reviews-reconciler
    namespace: flux-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: reviews-reconciler-cnpg
  namespace: reviews
rules:
  - apiGroups: ["postgresql.cnpg.io"]
    resources: ["clusters"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: reviews-reconciler-cnpg
  namespace: reviews
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: reviews-reconciler-cnpg
subjects:
  - kind: ServiceAccount
    name: reviews-reconciler
    namespace: flux-system
```

### HelmRelease

```yaml
# helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: reviews
  namespace: flux-system
spec:
  interval: 30m
  # The first install waits for Postgres to start.
  timeout: 10m
  releaseName: reviews
  targetNamespace: reviews
  storageNamespace: reviews
  serviceAccountName: reviews-reconciler
  chart:
    spec:
      chart: reviews
      version: "0.0.3"
      sourceRef:
        kind: HelmRepository
        name: reviews
  install:
    remediation:
      retries: 3
  upgrade:
    remediation:
      retries: 3
      strategy: rollback
  # Later entries win, so the pins file overrides values.yaml.
  valuesFrom:
    - kind: ConfigMap
      name: reviews-values
      valuesKey: values.yaml
    - kind: ConfigMap
      name: reviews-pins
      valuesKey: values.yaml
```

### Values and pins

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - reconciler.yaml
  - helmrepository.yaml
  - helmrelease.yaml
configMapGenerator:
  - name: reviews-values
    namespace: flux-system
    files:
      - values.yaml
  - name: reviews-pins
    namespace: flux-system
    files:
      - values.yaml=pins.yaml
configurations:
  - kustomizeconfig.yaml
```

```yaml
# kustomizeconfig.yaml
# Point valuesFrom at the generated ConfigMap names, which change with their
# content, so editing values.yaml or pins.yaml upgrades the release.
nameReference:
  - kind: ConfigMap
    version: v1
    fieldSpecs:
      - path: spec/valuesFrom/name
        kind: HelmRelease
```

```yaml
# values.yaml
host: reviews.example.com
secrets:
  existingSecret: reviews-env
ingress:
  enabled: true
  className: traefik
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
  tlsSecretName: reviews-tls
```

```yaml
# pins.yaml
# Empty runs server-v<chart version>. Set a sha- tag to run a build from main
# between releases, such as sha-8599da003156.
image:
  tag: ""
```

### Deploying a new version

To deploy a release, change `chart.spec.version` in `helmrelease.yaml` and
merge the change; the image follows the chart. To deploy a build from `main`
between releases, set its `sha-` tag in `pins.yaml` instead. Flux upgrades
the release on its next reconcile; `flux reconcile kustomization <name>
--with-source` does it now. If the new pods do not become ready within
`timeout`, Flux rolls back to the last good revision. The old pods keep
serving meanwhile, as long as the new image's migrations, which have already
run, are compatible with them. Flux's rollback does not revert migrations;
see [Migrations](#migrations).

A scheduled CI job can open that pull request: read the newest release (or
the newest `sha-` tag for a commit on `main`), write it to
`helmrelease.yaml` (or `pins.yaml`), and open a pull request. The merged
commit is then the deploy record. Chart versions are the `server-v<version>`
tags in this repository.

### Optional: image automation for releases

Flux's image automation can write the pin for you. It needs tags it can sort.
`sha-` tags have no order, so Flux cannot tell which one is newest. Release
tags are semver, so automation can follow releases:

```yaml
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageRepository
metadata:
  name: reviews
  namespace: flux-system
spec:
  image: ghcr.io/figitaki/reviews-server
  interval: 1h
---
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImagePolicy
metadata:
  name: reviews
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: reviews
  # Plain versions only: skips sha-, main, server-v and prerelease tags.
  filterTags:
    pattern: '^\d+\.\d+\.\d+$'
  policy:
    semver:
      range: ">=0.0.1"
---
apiVersion: image.toolkit.fluxcd.io/v1
kind: ImageUpdateAutomation
metadata:
  name: reviews
  namespace: flux-system
spec:
  interval: 1h
  sourceRef:
    kind: GitRepository
    name: flux-system
  git:
    checkout:
      ref:
        branch: main
    commit:
      author:
        name: fluxcdbot
        email: fluxcdbot@users.noreply.github.com
      messageTemplate: "Deploy Reviews {{range .Changed.Changes}}{{.NewValue}}{{end}}"
    push:
      branch: main
  update:
    path: ./apps/reviews
    strategy: Setters
```

Then mark the line in `pins.yaml` that Flux should rewrite:

```yaml
image:
  tag: 0.0.3 # {"$imagepolicy": "flux-system:reviews:tag"}
```

This changes only the image, not the chart: the release's server then runs
on the chart version you pinned. Prefer bumping `chart.spec.version`, which
moves both together.

The tradeoff: you deploy only releases, which ship less often than `main`,
and the deploy commit comes from Flux rather than a reviewed pull request.
Set `push.branch` to another branch if you want a pull request instead.
Following every `main` commit this way would need a sortable tag on `main`
images, such as one with the workflow run number. The image workflow does
not publish one today. Pinning `sha-` tags through pull requests, as above,
gives the same result with a review step.

## Known limits

- **Request budgets.** Release `0.0.3`, the chart's default image, has no
  per-client request budgets. They are in images built from `main` since
  [#157](https://github.com/figitaki/reviews/pull/157) (`sha-` tags) and will be in the next release; see
  [docs/ABUSE_PROTECTION.md](../../docs/ABUSE_PROTECTION.md). Those budgets
  key on the socket peer. Behind an ingress that peer is the ingress pod, so
  every visitor that comes through the same ingress pod shares one budget
  (300 requests a minute per app pod). Only Fly's `Fly-Client-IP` header is
  trusted today.
- **Database traffic is not encrypted.** The app connects to Postgres without
  TLS, which CloudNativePG allows by default. Restrict who can reach the
  database pods with a NetworkPolicy if that matters.
- **The server listens on IPv6 and IPv4 (`::`).** Nodes with IPv6 turned off
  in the kernel cannot bind it.
- **Open-file limit.** The chart sets `ERL_MAX_PORTS=65536`. Some container
  runtimes set the open-file limit near 2^30, and the BEAM would size its
  port table from it and use about 1 GB of memory at boot. Override it
  through `env` if you need more.

## Releasing the chart

The chart ships with every Reviews release; there are no chart-only tags.
[docs/RELEASE.md](../../docs/RELEASE.md) bumps `version` and `appVersion` in
`Chart.yaml` along with `mix.exs` and the other manifests. Pushing the
`server-v<version>` tag runs `.github/workflows/release-server-image.yml`,
which checks that every version matches the tag, publishes the image, then
runs `.github/scripts/check_chart.sh` and pushes the chart to
`oci://ghcr.io/figitaki/charts/reviews`.

A fix to the chart alone ships as a new patch release: bump every version
(for example `0.0.3` to `0.0.4`), add the fix to `CHANGELOG.md`, and tag
`server-v0.0.4`. The release also rebuilds the server image from the same
commit, so the new chart and its default image still match.

To check the chart locally, including that its versions match `mix.exs`:

```sh
.github/scripts/check_chart.sh
```
