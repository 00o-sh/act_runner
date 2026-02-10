{{/*
Expand the name of the chart.
*/}}
{{- define "act-runner-controller.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "act-runner-controller.fullname" -}}
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
{{- define "act-runner-controller.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "act-runner-controller.labels" -}}
helm.sh/chart: {{ include "act-runner-controller.chart" . }}
{{ include "act-runner-controller.selectorLabels" . }}
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
{{- define "act-runner-controller.selectorLabels" -}}
app.kubernetes.io/name: {{ include "act-runner-controller.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: autoscaler-config
{{- end }}

{{/*
Name of the Secret holding the Forgejo API token.
If the user provides a pre-existing secret name, use that.
Otherwise, generate one from the release fullname.
*/}}
{{- define "act-runner-controller.apiTokenSecretName" -}}
{{- if .Values.forgejo.apiTokenSecret.name }}
{{- .Values.forgejo.apiTokenSecret.name }}
{{- else }}
{{- printf "%s-forgejo-api" (include "act-runner-controller.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Whether the chart should create the API token Secret.
True when forgejo.apiToken is set and no pre-existing secret name is given.
*/}}
{{- define "act-runner-controller.createApiTokenSecret" -}}
{{- if and .Values.forgejo.apiToken (not .Values.forgejo.apiTokenSecret.name) }}
{{- true }}
{{- end }}
{{- end }}

{{/*
Name of the KEDA TriggerAuthentication resource.
*/}}
{{- define "act-runner-controller.triggerAuthName" -}}
{{- if .Values.triggerAuthentication.name }}
{{- .Values.triggerAuthentication.name }}
{{- else }}
{{- printf "%s-trigger-auth" (include "act-runner-controller.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Forgejo jobs API URL based on scope (admin vs org).
Note: This helper is provided for reference. The scale-set chart accepts
a full URL via keda.metricsUrl so users can target their exact endpoint.

Forgejo uses: /api/v1/admin/runners/jobs
Gitea uses:   /api/v1/admin/actions/jobs
*/}}
{{- define "act-runner-controller.jobsApiUrl" -}}
{{- $url := .Values.forgejo.url | default "" | trimSuffix "/" -}}
{{- if eq (.Values.forgejo.scope | default "admin") "org" -}}
{{- printf "%s/api/v1/orgs/%s/actions/jobs?status=waiting&limit=1" $url (.Values.forgejo.org | default "") }}
{{- else -}}
{{- printf "%s/api/v1/admin/runners/jobs?status=waiting&limit=1" $url }}
{{- end -}}
{{- end }}
