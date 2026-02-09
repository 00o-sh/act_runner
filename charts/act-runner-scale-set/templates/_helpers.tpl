{{/*
Expand the name of the chart.
*/}}
{{- define "act-runner-scale-set.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "act-runner-scale-set.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "act-runner-scale-set.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "act-runner-scale-set.labels" -}}
helm.sh/chart: {{ include "act-runner-scale-set.chart" . }}
{{ include "act-runner-scale-set.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.additionalLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "act-runner-scale-set.selectorLabels" -}}
app.kubernetes.io/name: {{ include "act-runner-scale-set.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: runner
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "act-runner-scale-set.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "act-runner-scale-set.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Runner image reference - selects the correct tag variant based on containerMode
*/}}
{{- define "act-runner-scale-set.image" -}}
{{- $containerType := .Values.containerMode.type | default "" -}}
{{- if .Values.image.tag }}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag }}
{{- else }}
{{- $tag := .Chart.AppVersion }}
{{- if eq $containerType "dind" }}
{{- printf "%s:%s-dind" .Values.image.repository $tag }}
{{- else if eq $containerType "dind-rootless" }}
{{- printf "%s:%s-dind-rootless" .Values.image.repository $tag }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository $tag }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Runner scale set name (used as runner name prefix)
*/}}
{{- define "act-runner-scale-set.runnerScaleSetName" -}}
{{- default .Release.Name .Values.runnerScaleSetName | trunc 45 | trimSuffix "-" }}
{{- end }}

{{/*
Determine if we should create a Secret for the registration token.
True when giteaConfigSecret is a map with a .token value and no .name override.
*/}}
{{- define "act-runner-scale-set.createSecret" -}}
{{- if kindIs "map" .Values.giteaConfigSecret }}
  {{- if and (index .Values.giteaConfigSecret "token") (not (index .Values.giteaConfigSecret "name")) }}
    {{- true }}
  {{- end }}
{{- end }}
{{- end }}

{{/*
Secret name for Gitea registration token.
Supports giteaConfigSecret as:
  - a string: used directly as the Secret name
  - a map with .name: used as the Secret name
  - a map with .token (no .name): generates a name from the release
*/}}
{{- define "act-runner-scale-set.secretName" -}}
{{- if kindIs "string" .Values.giteaConfigSecret }}
{{- .Values.giteaConfigSecret }}
{{- else if and (kindIs "map" .Values.giteaConfigSecret) (index .Values.giteaConfigSecret "name") }}
{{- index .Values.giteaConfigSecret "name" }}
{{- else }}
{{- printf "%s-gitea-secret" (include "act-runner-scale-set.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Config map name for runner config
*/}}
{{- define "act-runner-scale-set.configMapName" -}}
{{- printf "%s-config" (include "act-runner-scale-set.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
