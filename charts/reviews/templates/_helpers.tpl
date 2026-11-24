{{- define "reviews.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- /*
At most 47 characters, so every derived name fits: the CloudNativePG Cluster
<fullname>-db (the operator allows 50 and adds its own -rw, -app and other
suffixes), <fullname>-headless, <fullname>-config and <fullname>-secrets. A longer name keeps its
first 38 characters plus 8 hex of its SHA-256, so names that share a prefix
stay distinct.
*/}}
{{- define "reviews.fullname" -}}
{{- $name := "" }}
{{- if .Values.fullnameOverride }}
{{- $name = .Values.fullnameOverride }}
{{- else if contains (include "reviews.name" .) .Release.Name }}
{{- $name = .Release.Name }}
{{- else }}
{{- $name = printf "%s-%s" .Release.Name (include "reviews.name" .) }}
{{- end }}
{{- if gt (len $name) 47 }}
{{- printf "%s-%s" ($name | trunc 38 | trimSuffix "-") ($name | sha256sum | trunc 8) }}
{{- else }}
{{- $name }}
{{- end }}
{{- end }}

{{- define "reviews.selectorLabels" -}}
app.kubernetes.io/name: {{ include "reviews.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "reviews.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "reviews.selectorLabels" . }}
app.kubernetes.io/version: {{ include "reviews.imageTag" . | trunc 63 | trimSuffix "-" | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "reviews.imageTag" -}}
{{- .Values.image.tag | default (printf "server-v%s" .Chart.AppVersion) }}
{{- end }}

{{- define "reviews.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s:%s@%s" .Values.image.repository (include "reviews.imageTag" .) .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (include "reviews.imageTag" .) }}
{{- end }}
{{- end }}

{{- define "reviews.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "reviews.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "reviews.secretName" -}}
{{- .Values.secrets.existingSecret | default (printf "%s-secrets" (include "reviews.fullname" .)) }}
{{- end }}

{{- define "reviews.dbClusterName" -}}
{{- printf "%s-db" (include "reviews.fullname" .) }}
{{- end }}

{{- define "reviews.configName" -}}
{{- printf "%s-config" (include "reviews.fullname" .) }}
{{- end }}

{{- define "reviews.headlessName" -}}
{{- printf "%s-headless" (include "reviews.fullname" .) }}
{{- end }}

{{/* DATABASE_URL: the CloudNativePG app Secret, or the user's Secret. */}}
{{- define "reviews.databaseUrlRef" -}}
{{- if .Values.database.cluster.enabled }}
name: {{ include "reviews.dbClusterName" . }}-app
key: uri
{{- else }}
name: {{ required "database.existingSecret is required when database.cluster.enabled is false" .Values.database.existingSecret }}
key: {{ .Values.database.existingSecretKey }}
{{- end }}
{{- end }}

{{/* Environment shared by the app container and the migration init container. */}}
{{- define "reviews.env" -}}
{{- /* Plain settings are in the config file (reviews.configFile); an env var would override it. */}}
- name: REVIEWS_CONFIG
  value: /etc/reviews/reviews.yaml
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      {{- include "reviews.databaseUrlRef" . | trim | nindent 6 }}
{{- /*
Copies of config file settings as environment variables, for one release so
tooling that reads pod env keeps working. They come from the rendered file,
so they always agree with it. Removed in the release after 0.0.5.
*/}}
{{- $file := include "reviews.configFile" . | fromYaml }}
- name: PHX_HOST
  value: {{ $file.server.host | quote }}
- name: PORT
  value: "4000"
- name: POOL_SIZE
  value: {{ $file.database.pool_size | int | toString | quote }}
- name: ECTO_IPV6
  value: {{ $file.database.ipv6 | toString | quote }}
- name: MCP_ENABLED
  value: {{ $file.mcp.enabled | toString | quote }}
- name: MCP_WRITES_ENABLED
  value: {{ $file.mcp.writes_enabled | toString | quote }}
{{- range $key, $value := ($file.legal | default dict) }}
- name: {{ printf "LEGAL_%s" (upper $key) }}
  value: {{ $value | toString | quote }}
{{- end }}
{{- with ($file.cluster | default dict).dns_query }}
- name: DNS_CLUSTER_QUERY
  value: {{ . | quote }}
{{- end }}
{{- /* The release writes its runtime config under RELEASE_TMP; the root filesystem is read-only. */}}
{{- /* The BEAM sizes its port table from the open-file limit. Some container runtimes set it near 2^30, which costs about 1 GB at boot. */}}
{{- if not (hasKey .Values.env "ERL_MAX_PORTS") }}
- name: ERL_MAX_PORTS
  value: "65536"
{{- end }}
- name: RELEASE_TMP
  value: /tmp
{{- /* The release always starts Erlang distribution, and the image's built-in cookie is public, so every pod needs a private one. Not optional: a pod without it does not start. */}}
- name: RELEASE_COOKIE
  valueFrom:
    secretKeyRef:
      name: {{ include "reviews.secretName" . }}
      key: RELEASE_COOKIE
{{- if .Values.clustering.enabled }}
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
{{- /* A long node name needs a dotted host; the pod IP is one that peers can reach. */}}
- name: RELEASE_NODE
  value: reviews@$(POD_IP)
{{- else }}
{{- /* Without clustering, epmd and the distribution port listen on loopback only, so nothing outside the pod can reach them. */}}
- name: RELEASE_NODE
  value: reviews@127.0.0.1
- name: ERL_EPMD_ADDRESS
  value: 127.0.0.1
- name: ERL_ZFLAGS
  value: "-kernel inet_dist_use_interface {127,0,0,1}"
{{- end }}
{{- range $name, $value := .Values.env }}
- name: {{ $name }}
  value: {{ $value | quote }}
{{- end }}
{{- end }}

{{- define "reviews.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}

{{- /*
The server's config file (docs/CONFIGURATION.md), built from the chart's
values. `config` is merged over it, so any file key can be set there.
Secrets stay in the Secret, which reaches the app as environment variables.
*/}}
{{- define "reviews.configFile" -}}
{{- $file := dict
  "server" (dict "host" (required "host is required" .Values.host))
  "database" (dict "pool_size" (int .Values.database.poolSize) "ipv6" .Values.database.ipv6)
  "mcp" (dict "enabled" .Values.mcp.enabled "writes_enabled" .Values.mcp.writesEnabled) -}}
{{- if .Values.clustering.enabled }}
{{- $_ := set $file "cluster" (dict "dns_query" (printf "%s.%s.svc.cluster.local" (include "reviews.headlessName" .) .Release.Namespace)) }}
{{- end }}
{{- /* Only the legal settings that are filled in; see docs/LEGAL_PAGES.md. */}}
{{- $legal := dict }}
{{- range $key, $name := dict "privacyUrl" "privacy_url" "termsUrl" "terms_url" "operatorName" "operator_name" "contactEmail" "contact_email" "updated" "updated" "hostingRegion" "hosting_region" "logRetention" "log_retention" "backupRetention" "backup_retention" "governingLaw" "governing_law" "venue" "venue" "liabilityCap" "liability_cap" }}
{{- with index ($.Values.legal | default dict) $key }}
{{- $_ := set $legal $name (toString .) }}
{{- end }}
{{- end }}
{{- if $legal }}
{{- $_ := set $file "legal" $legal }}
{{- end }}
{{- toYaml (mergeOverwrite $file (deepCopy (.Values.config | default dict))) }}
{{- end }}
