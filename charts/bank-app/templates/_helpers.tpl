{{/* Labels on every object. */}}
{{- define "bank-app.labels" -}}
{{- /* Labels may not contain "+", which Flux adds to OCI chart versions (1.0.3+<digest>). */}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/part-of: bank-app
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/* Selects the app pods (also used by the NetworkPolicies). */}}
{{- define "bank-app.appSelector" -}}
app.kubernetes.io/name: bank-app
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Selects the database pod. */}}
{{- define "bank-app.dbSelector" -}}
app.kubernetes.io/name: postgres
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "bank-app.dbName" -}}
{{ .Release.Name }}-postgres
{{- end }}

{{/*
Container security context shared by every container. Matches Pod Security "restricted".
*/}}
{{- define "bank-app.containerSecurityContext" -}}
runAsNonRoot: true
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end }}
