{{- define "reviews.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "reviews.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else if contains (include "reviews.name" .) .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "reviews.name" .) | trunc 63 | trimSuffix "-" }}
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
{{- .Values.image.tag | default .Chart.AppVersion }}
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
{{- printf "%s-db" (include "reviews.fullname" .) | trunc 50 | trimSuffix "-" }}
{{- end }}

{{- define "reviews.headlessName" -}}
{{- /* Leave room for the suffix, so a 63-character fullname cannot collide with the app Service. */}}
{{- printf "%s-headless" (include "reviews.fullname" . | trunc 54 | trimSuffix "-") }}
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
- name: PHX_HOST
  value: {{ required "host is required" .Values.host | quote }}
- name: PORT
  value: "4000"
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      {{- include "reviews.databaseUrlRef" . | trim | nindent 6 }}
- name: POOL_SIZE
  value: {{ .Values.database.poolSize | quote }}
- name: ECTO_IPV6
  value: {{ .Values.database.ipv6 | quote }}
- name: MCP_ENABLED
  value: {{ .Values.mcp.enabled | quote }}
- name: MCP_WRITES_ENABLED
  value: {{ .Values.mcp.writesEnabled | quote }}
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
{{- if .Values.clustering.enabled }}
- name: DNS_CLUSTER_QUERY
  value: {{ printf "%s.%s.svc.cluster.local" (include "reviews.headlessName" .) .Release.Namespace | quote }}
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
